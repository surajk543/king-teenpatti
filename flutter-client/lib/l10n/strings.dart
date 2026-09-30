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

/// The lobby's name for a Teen Patti or poker game, as a name: the app's own
/// words, written in capitals on the lobby's badges ("TEEN PATTI", "SEEN"),
/// set in title case where the script has case ("Teen Patti", "Seen"). A
/// script without case — Devanagari, Bengali, Gujarati, Gurmukhi — and a name
/// already in mixed case ("Texas Hold'em") are left exactly as they are.
///
/// Where a game is named in a sentence or on a key rather than a badge: a
/// playing friend's line on the Friends page, and the games a player's record
/// is kept in.
String friendlyName(String name) {
  if (name != name.toUpperCase() || name == name.toLowerCase()) return name;
  return name
      .split(' ')
      .map(
        (word) => word.isEmpty
            ? word
            : '${word.substring(0, 1)}${word.substring(1).toLowerCase()}',
      )
      .join(' ');
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

  // --- player stats v2 (owner, 27 Sep 2026): a record kept game by game —
  // All, then Teen Patti, Variation and Poker by the lobby's own names for
  // them ([friendlyName] of [teenPatti], [variation] and [poker]).
  String get statsAll => _('statsAll');

  /// Over the six hands a player held at Teen Patti or Variation tables, each
  /// named as the table names it — in the server's English.
  String get handsHeld => _('handsHeld');

  /// Over the variations a player's Variation hands were played under, each
  /// by the picker's name for it ([variationName]).
  String get variationsPlayed => _('variationsPlayed');

  /// The headings over each variation's hands played and hands won: short,
  /// since they set the width of the two columns of figures under them.
  String get statsPlayed => _('statsPlayed');
  String get statsWon => _('statsWon');

  /// Where no Variation hand has been played yet.
  String get statsNoVariations => _('statsNoVariations');

  // --- the lobby's Stats drawer (owner, 27 Sep 2026: "one continuous player
  // profile" — no tabs, and no Poker in it): the scope is a small menu over
  // the record, and the record's parts go by these names. The section names
  // are set in tracked capitals in English only, as the Settings drawer's are.
  String get statsPerformance => _('statsPerformance');

  /// The menu's three scopes: every game together, then the two games the
  /// drawer shows on their own (Teen Patti by [teenPatti]'s own name).
  String get statsAllGames => _('statsAllGames');
  String get statsVariations => _('statsVariations');

  /// What the menu chooses, said to a screen reader before its value.
  String get statsScopeLabel => _('statsScopeLabel');

  /// Over the six hands a player finished with — "Hands held" renamed.
  String get statsHandResults => _('statsHandResults');
  String get statsNoHandResults => _('statsNoHandResults');
  String get statsNoVariationGames => _('statsNoVariationGames');

  /// Where the scope on show does not count a part: which scopes do.
  String get statsHandResultsHint => _('statsHandResultsHint');
  String get statsVariationsHint => _('statsVariationsHint');

  // --- a wallet filled in the lobby: its celebration
  String get rewardCollected => _('rewardCollected');
  String get rewardPurchased => _('rewardPurchased');
  String get rewardDiamondsPurchased => _('rewardDiamondsPurchased');
  String get rewardHammersPurchased => _('rewardHammersPurchased');
  String get tapToClose => _('tapToClose');

  // --- the Lucky Draw (owner, 24 Sep 2026): a wheel of six prizes the
  // server spins. The chip's title is capitals, as the lobby's corner chips'
  // always were; the screen's is the name as a name.
  String get luckyDrawChip => _('luckyDrawChip');
  String get luckyDrawTitle => _('luckyDrawTitle');
  String get luckySpinReady => _('luckySpinReady');
  String get luckySpinNow => _('luckySpinNow');
  String get luckySpinning => _('luckySpinning');
  String get luckyNextSpin => _('luckyNextSpin');

  /// The polish of 26 Sep 2026: "FREE SPIN" beside the title while a spin is
  /// due, and "NEXT FREE SPIN" over the wait on the key while it is not.
  String get luckyFreeSpin => _('luckyFreeSpin');
  String get luckyNextFreeSpin => _('luckyNextFreeSpin');

  /// "One free spin every 3 days." — [time] written by [rentalTerm].
  String luckyEvery(String time) => _('luckyEvery').replaceAll('{time}', time);

  // --- the reward programs (owner, 30 Sep 2026): the login streaks and the
  // calendar rewards — the lobby's corner chip, their screen and the
  // celebration of a claim. The server names a program (its `name`); the app
  // names the four it knows in the player's language (rewardProgramName).

  /// The lobby chip's title.
  String get rewardsChip => _('rewardsChip');

  /// The screen's title.
  String get rewardsTitle => _('rewardsTitle');

  /// The chip's second line while a reward waits to be collected, and once
  /// every program's today is collected.
  String get rewardsCollect => _('rewardsCollect');
  String get rewardsCollected => _('rewardsCollected');

  /// The celebration's title over what a claim gave.
  String get rewardsCollectedTitle => _('rewardsCollectedTitle');

  /// "3 day streak" — a login streak's headline. One day has its own line.
  String streakDays(int n) =>
      _(n == 1 ? 'streakDayOne' : 'streakDays').replaceAll('{n}', '$n');

  /// A streak's headline while its run has not begun.
  String get streakStart => _('streakStart');

  /// "Day 10 reward" — a calendar's headline: today's place in the period.
  String calendarDayReward(int n) =>
      _('calendarDayReward').replaceAll('{n}', '$n');

  /// The mode tag on a program's panel.
  String get rewardModeStreak => _('rewardModeStreak');
  String get rewardModeCalendar => _('rewardModeCalendar');

  /// What each mode means, under the panel's head.
  String get rewardStreakHint => _('rewardStreakHint');
  String get rewardStreakHintNoReset => _('rewardStreakHintNoReset');
  String get rewardCalendarWeekHint => _('rewardCalendarWeekHint');
  String get rewardCalendarMonthHint => _('rewardCalendarMonthHint');

  /// "Next reward" — the panel's foot, before what the next day gives.
  String get rewardNext => _('rewardNext');

  /// "Day 3" on a streak's tile.
  String rewardDay(int n) => _('rewardDay').replaceAll('{n}', '$n');
  String get rewardToday => _('rewardToday');

  /// A tile's state, for a screen reader.
  String get rewardTileClaimed => _('rewardTileClaimed');
  String get rewardTileLocked => _('rewardTileLocked');
  String get rewardTileMissed => _('rewardTileMissed');

  /// The screen with no program running, or none it could read.
  String get rewardNone => _('rewardNone');
  String get rewardLoadFailed => _('rewardLoadFailed');

  /// A claim refused at a table.
  String get rewardLobbyOnly => _('rewardLobbyOnly');

  /// A day that gives nothing.
  String get rewardNothing => _('rewardNothing');

  /// After an item the player already had: "(already yours)".
  String get rewardAlreadyOwned => _('rewardAlreadyOwned');

  /// An item reward named: "Clapping Hands emoji", "Royal Ace badge · 7 days".
  String rewardEmojiName(String name) =>
      _('rewardEmojiName').replaceAll('{name}', name);
  String rewardPictureName(String name) =>
      _('rewardPictureName').replaceAll('{name}', name);
  String rewardTablePictureName(String name) =>
      _('rewardTablePictureName').replaceAll('{name}', name);
  String rewardBadgeName(String name) =>
      _('rewardBadgeName').replaceAll('{name}', name);
  String rewardBadgeDays(String name, int days) => _(
    'rewardBadgeDays',
  ).replaceAll('{name}', name).replaceAll('{n}', '$days');

  /// The four seeded programs in the player's language; any other program
  /// by the name the server gave it.
  String rewardProgramName(String code, String fallback) => switch (code) {
    'WEEKLY_LOGIN' => _('rewardProgramWeeklyLogin'),
    'MONTHLY_LOGIN' => _('rewardProgramMonthlyLogin'),
    'WEEKLY_CALENDAR' => _('rewardProgramWeeklyCalendar'),
    'MONTHLY_CALENDAR' => _('rewardProgramMonthlyCalendar'),
    _ => fallback,
  };

  /// A weekday's short name, 1 Monday … 7 Sunday.
  String weekdayShort(int iso) => _('weekday${iso.clamp(1, 7)}');

  /// The weekly login popup's foot: "Today's reward: 20,000 chips".
  String todaysReward(String prize) =>
      _('todaysReward').replaceAll('{prize}', prize);

  /// What the other programs gave with the same tap: "Also: Clapping Hands
  /// emoji".
  String rewardsAlso(String list) =>
      _('rewardsAlso').replaceAll('{list}', list);

  /// The weekly login popup's headings and key (the owner's polish brief,
  /// 30 Sep 2026): "Today's reward" over the prize, "Continue" once it is
  /// collected, and "FINAL" on the seventh day's card.
  String get todaysRewardTitle => _('todaysRewardTitle');
  String get continueKey => _('continueKey');
  String get weeklyFinal => _('weeklyFinal');
  String get luckyPrizes => _('luckyPrizes');
  String get luckyNoPrize => _('luckyNoPrize');
  String get luckyCongrats => _('luckyCongrats');
  String get luckyYouWon => _('luckyYouWon');
  String get luckyNothingTitle => _('luckyNothingTitle');
  String get luckyNothingBody => _('luckyNothingBody');
  String get luckyAlreadyOwned => _('luckyAlreadyOwned');

  /// "Yours for 50 days" under a picture won — [time] by [rentalTerm]; a
  /// picture that never runs out says [pictureKeeps] instead.
  String luckyPictureFor(String time) =>
      _('luckyPictureFor').replaceAll('{time}', time);
  String get luckyWearNow => _('luckyWearNow');
  String get luckyLayNow => _('luckyLayNow');
  String get luckyProfilePicture => _('luckyProfilePicture');
  String get luckyTablePicture => _('luckyTablePicture');
  String get luckyClosed => _('luckyClosed');
  String get luckyLoadFailed => _('luckyLoadFailed');
  String get luckyRetry => _('luckyRetry');
  String get luckyLobbyOnly => _('luckyLobbyOnly');
  String get luckyNotReady => _('luckyNotReady');

  /// A missile count in words — "1 missile", "2 missiles" — for a prize. One
  /// missile has its own line in every language, as [missilesAdded]'s does.
  String countMissiles(int n) =>
      _(n == 1 ? 'countMissileOne' : 'countMissiles').replaceAll('{n}', '$n');

  // --- the welcome (30 Sep 2026): the toast a new account's sign-in raises,
  // naming exactly what the server's welcome grant gave it. The wallets are
  // said by [priceIn] and [countMissiles]; the catalogues' rows are counted.

  /// "Welcome! Added to your account: 10 Lakh chips · 9 diamonds" — [items]
  /// the grant's own words, joined.
  String welcomeAdded(String items) =>
      _('welcomeAdded').replaceAll('{items}', items);

  /// A welcome that granted nothing: no list.
  String get welcomePlain => _('welcomePlain');

  /// "1 picture", "2 pictures" — profile pictures granted.
  String countPictures(int n) =>
      _(n == 1 ? 'countPictureOne' : 'countPictures').replaceAll('{n}', '$n');

  /// "1 table picture", "2 table pictures".
  String countTablePictures(int n) => _(
    n == 1 ? 'countTablePictureOne' : 'countTablePictures',
  ).replaceAll('{n}', '$n');

  /// "1 emoji", "2 emojis".
  String countEmojis(int n) =>
      _(n == 1 ? 'countEmojiOne' : 'countEmojis').replaceAll('{n}', '$n');

  // --- Friends (owner, 26 Sep 2026): the lobby's key, the page, Add Friend
  // and a player's profile. Nothing here names a wallet.
  String get friends => _('friends');

  /// The key's badge, spoken: "2 new friend requests".
  String friendRequestsWaiting(int n) => _(
    n == 1 ? 'friendRequestWaiting' : 'friendRequestsWaiting',
  ).replaceAll('{n}', '$n');
  String get yourPlayerId => _('yourPlayerId');
  String get copyId => _('copyId');
  String get idCopied => _('idCopied');
  String get addFriend => _('addFriend');
  String get friendRequests => _('friendRequests');
  String get noFriendRequests => _('noFriendRequests');
  String get noFriendsTitle => _('noFriendsTitle');
  String get noFriendsBody => _('noFriendsBody');
  String get friendsLoadFailed => _('friendsLoadFailed');
  String get friendsRetry => _('friendsRetry');
  String get friendAccept => _('friendAccept');
  String get friendReject => _('friendReject');
  String get wantsToBeFriends => _('wantsToBeFriends');
  String get presenceOnline => _('presenceOnline');

  /// How many friends are online, beside the table's own drawer's Friends
  /// tab: "3 online".
  String friendsOnlineCount(int n) =>
      _('friendsOnlineCount').replaceAll('{n}', '$n');
  String get presenceOffline => _('presenceOffline');
  String get playingNow => _('playingNow');
  String get addFriendHint => _('addFriendHint');

  /// Under the empty search: where a friend finds the ID to give.
  String get addFriendHowTo => _('addFriendHowTo');
  String get playerIdLabel => _('playerIdLabel');
  String get searchPlayer => _('searchPlayer');
  String get requestSent => _('requestSent');
  String get thatsYou => _('thatsYou');
  String get enterPlayerId => _('enterPlayerId');
  String get playerProfile => _('playerProfile');
  String get winRate => _('winRate');
  String get removeFriend => _('removeFriend');

  /// "Remove Ravi from your friends?"
  String removeFriendQ(String name) =>
      _('removeFriendQ').replaceAll('{name}', name);
  String get removeFriendBody => _('removeFriendBody');
  String get removeFriendConfirm => _('removeFriendConfirm');
  String get profileLoadFailed => _('profileLoadFailed');
  String get back => _('back');

  /// "Ravi is now your friend." — an accepted request.
  String friendAdded(String name) =>
      _('friendAdded').replaceAll('{name}', name);

  /// "Ravi is no longer your friend." — a friend removed.
  String friendRemoved(String name) =>
      _('friendRemoved').replaceAll('{name}', name);

  /// "Ravi sent you a friend request." — a request that has just arrived
  /// (`friend:request`), wherever the player is.
  String friendRequestArrived(String name) =>
      _('friendRequestArrived').replaceAll('{name}', name);

  /// The same, at a table the sender sits at: where to answer it — their
  /// seat, which wears the request's badge.
  String friendRequestAtTable(String name) =>
      _('friendRequestAtTable').replaceAll('{name}', name);

  /// "Ravi accepted your friend request." — one of the player's own requests
  /// accepted (`friend:accepted`).
  String friendAcceptedYours(String name) =>
      _('friendAcceptedYours').replaceAll('{name}', name);

  /// What the small mark on a friend's seat at a table says to a screen
  /// reader: this player is the viewer's friend.
  String get friendMark => _('friendMark');

  /// Every refusal a Friends route can answer, in words
  /// (`friendsRefusalText` picks by code).
  String get friendRefusePlayerNotFound => _('friendRefusePlayerNotFound');
  String get friendRefuseInvalidId => _('friendRefuseInvalidId');
  String get friendRefuseSelf => _('friendRefuseSelf');
  String get friendRefuseAlreadyFriends => _('friendRefuseAlreadyFriends');
  String get friendRefuseAlreadySent => _('friendRefuseAlreadySent');
  String get friendRefuseAlreadyReceived => _('friendRefuseAlreadyReceived');
  String get friendRefuseRequestGone => _('friendRefuseRequestGone');
  String get friendRefuseNotPending => _('friendRefuseNotPending');
  String get friendRefuseNotFriends => _('friendRefuseNotFriends');
  String get friendRefuseRateLimited => _('friendRefuseRateLimited');
  String get friendActionFailed => _('friendActionFailed');

  // --- Report Player (owner, 27 Sep 2026): the table's player drawer
  String get reportPlayer => _('reportPlayer');
  String get reportWhy => _('reportWhy');
  String get reportReasonCheating => _('reportReasonCheating');
  String get reportReasonHarassment => _('reportReasonHarassment');
  String get reportReasonAbusiveLanguage => _('reportReasonAbusiveLanguage');
  String get reportReasonSpam => _('reportReasonSpam');
  String get reportReasonInappropriate => _('reportReasonInappropriate');
  String get reportReasonSuspicious => _('reportReasonSuspicious');
  String get reportReasonCollusion => _('reportReasonCollusion');
  String get reportReasonExploit => _('reportReasonExploit');
  String get reportReasonOther => _('reportReasonOther');
  String get reportDetails => _('reportDetails');
  String get reportDetailsHint => _('reportDetailsHint');
  String get reportDetailsRequiredHint => _('reportDetailsRequiredHint');
  String get reportSubmit => _('reportSubmit');
  String get reportSubmitting => _('reportSubmitting');

  /// The thank-you after a report is filed: "✓ Report submitted", then the
  /// two lines the brief gives, word for word in English.
  String get reportSubmitted => _('reportSubmitted');
  String get reportThanks => _('reportThanks');
  String get reportReview => _('reportReview');
  String get reportDone => _('reportDone');

  /// The drawer's quiet line for a player already reported this session.
  String get reportedTag => _('reportedTag');

  /// Every refusal the report route can answer, in words
  /// (`reportRefusalText` picks by code).
  String get reportAlready => _('reportAlready');
  String get reportLimited => _('reportLimited');
  String get reportNotAtTable => _('reportNotAtTable');
  String get reportInvalidPlayer => _('reportInvalidPlayer');
  String get reportDescriptionRequired => _('reportDescriptionRequired');
  String get reportDescriptionTooLong => _('reportDescriptionTooLong');
  String get reportNetworkError => _('reportNetworkError');
  String get reportServerError => _('reportServerError');

  /// The report limit used (owner, 27 Sep 2026: "if user has reported 2
  /// player, then reporting by him should be disabled in UI, and show a cool
  /// down time in UI when can he report again"): the drawer's dead Report
  /// line, how many of the limit are used, and the countdown to the next.
  String get reportLimitTitle => _('reportLimitTitle');
  String reportLimitUsed(int used, int max) => _(
    'reportLimitUsed',
  ).replaceFirst('{used}', '$used').replaceFirst('{max}', '$max');
  String reportAgainIn(String time) =>
      _('reportAgainIn').replaceFirst('{time}', time);

  /// The Friends page's Reported tab (owner, 27 Sep 2026): the players this
  /// player reported, with each report's status and when it was filed.
  String get reportedTab => _('reportedTab');
  String get myReportsTitle => _('myReportsTitle');
  String get noReportsYet => _('noReportsYet');
  String get reportsLoadFailed => _('reportsLoadFailed');
  String get reportedPlayerGone => _('reportedPlayerGone');
  String get reportStatusPending => _('reportStatusPending');
  String get reportStatusUnderReview => _('reportStatusUnderReview');
  String get reportStatusActionTaken => _('reportStatusActionTaken');
  String get reportStatusDismissed => _('reportStatusDismissed');
  String reportedOn(String when) =>
      _('reportedOn').replaceFirst('{when}', when);

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

  /// The store's Tables shelf (owner, 15 Sep 2026): the cloths a player lays
  /// on their own table, each a day and a night picture.
  String get storeTabTables => _('storeTabTables');
  String get storeTablesTitle => _('storeTablesTitle');
  String get storeTablesBlurb => _('storeTablesBlurb');

  /// The first tile of that shelf — the default background, the chips drifting
  /// across the room, which laying no picture restores (owner, 15 Sep 2026)
  /// — and the word on the tile that is in use.
  String get tableDefault => _('tableDefault');
  String get tableDefaultHint => _('tableDefaultHint');
  String get tableInUse => _('tableInUse');

  /// The unlock question for a table picture, with the price written out by
  /// [priceIn] and, for a rental, its term by [rentalTerm].
  String get unlockTableTitle => _('unlockTableTitle');
  String unlockTableBody(String name, String price) => _(
    'unlockTableBody',
  ).replaceAll('{name}', name).replaceAll('{price}', price);
  String unlockTableRentBody(String name, String price, String time) =>
      _('unlockTableRentBody')
          .replaceAll('{name}', name)
          .replaceAll('{price}', price)
          .replaceAll('{time}', time);

  /// Said instead of asking when a chip-priced table picture is tapped at a
  /// table, as [pictureChipsLobbyOnly] is for a face.
  String get tableChipsLobbyOnly => _('tableChipsLobbyOnly');

  /// Said when a table picture is laid at a POKER room, whose felt shows
  /// none (the picture waits for the next Teen Patti table), and as the
  /// Tables shelf's blurb there.
  String get tablePokerNote => _('tablePokerNote');

  // --- emojis (owner, 26 Sep 2026: animated emojis a player buys and sends
  // to the whole table, like a chat line)

  /// The store's Emojis shelf: its key, its title and its line.
  String get storeTabEmojis => _('storeTabEmojis');
  String get storeEmojisTitle => _('storeEmojisTitle');
  String get storeEmojisBlurb => _('storeEmojisBlurb');

  /// Said where the catalogue holds no emoji at all.
  String get emojiShelfEmpty => _('emojiShelfEmpty');

  /// The unlock question for an emoji, with the price written out by
  /// [priceIn] and, for a rental, its term by [rentalTerm].
  String get unlockEmojiTitle => _('unlockEmojiTitle');
  String unlockEmojiBody(String name, String price) => _(
    'unlockEmojiBody',
  ).replaceAll('{name}', name).replaceAll('{price}', price);
  String unlockEmojiRentBody(String name, String price, String time) =>
      _('unlockEmojiRentBody')
          .replaceAll('{name}', name)
          .replaceAll('{price}', price)
          .replaceAll('{time}', time);

  /// Said instead of asking when a chip-priced emoji is tapped at a table,
  /// as [pictureChipsLobbyOnly] is for a face — and the server's `seated`.
  String get emojiChipsLobbyOnly => _('emojiChipsLobbyOnly');

  /// Said when an emoji the player owns is tapped in the store: it is sent
  /// from the table, not from here.
  String get emojiOwnedNote => _('emojiOwnedNote');

  /// The table's emoji key and the drawer page it opens: its name, the line
  /// under it, the heading over the locked ones, and the line where the
  /// player owns none yet.
  String get tableEmojis => _('tableEmojis');
  String get emojiSendHint => _('emojiSendHint');
  String get emojiUnlockMore => _('emojiUnlockMore');
  String get emojiNoneOwned => _('emojiNoneOwned');

  /// What a screen reader says for an emoji line in the chat.
  String emojiSentBy(String name, String emoji) =>
      _('emojiSentBy').replaceAll('{name}', name).replaceAll('{emoji}', emoji);

  /// The server's emoji refusals, by code.
  String get emojiLockedRefusal => _('emojiLockedRefusal');
  String get emojiUnknownRefusal => _('emojiUnknownRefusal');
  String get emojiRetiredRefusal => _('emojiRetiredRefusal');
  String get emojiUnaffordableRefusal => _('emojiUnaffordableRefusal');

  /// A price with its wallet's word: "50,000 chips", "5 diamonds", "1 hammer".
  /// [cost] arrives formatted for chips and diamonds; a hammer count is bare,
  /// and one hammer — and one diamond (23 Sep 2026: the four other languages
  /// carry the plural noun, so "1 हीरे" read wrong) — has its own line in
  /// every language, as elsewhere. `{s}` pluralises the English diamond and is
  /// absent from the other four.
  String priceIn(String currency, String cost) => switch (currency) {
    'HAMMER' =>
      cost == '1'
          ? _('priceHammerOne')
          : _('priceHammers').replaceAll('{cost}', cost),
    'DIAMOND' =>
      cost == '1'
          ? _('priceDiamondOne')
          : _(
              'priceDiamonds',
            ).replaceAll('{cost}', cost).replaceAll('{s}', 's'),
    _ => _('priceChips').replaceAll('{cost}', cost),
  };
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
  String get forceSideshowTooLate => _('forceSideshowTooLate');
  String get settings => _('settings');
  String get language => _('language');

  /// The settings drawer's line under its title, and the names of its groups
  /// (the settings polish, 26 Sep 2026). A group's name is set in tracked
  /// capitals in English only; the other scripts keep their own shape. The
  /// Appearance group is named by [appearance].
  String get settingsSubtitle => _('settingsSubtitle');
  String get settingsProfile => _('settingsProfile');
  String get settingsGameExperience => _('settingsGameExperience');
  String get settingsAccount => _('settingsAccount');

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
  String get deleteAccount => _('deleteAccount');
  String get deleteAccountTitle => _('deleteAccountTitle');
  String get deleteAccountBody => _('deleteAccountBody');
  String get deleteAccountSeated => _('deleteAccountSeated');
  String get deleteAccountConfirm => _('deleteAccountConfirm');
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

  /// The lobby's levels: the categories and one category's tables (owner,
  /// 18 Sep 2026), under the two engines since 23 Sep 2026. [viewTables] is
  /// the category card's key, as [tapToSit] is the table card's;
  /// [tablesLabel] and [openToYouLabel] are its two facts; [backToCategories]
  /// is what the tile at the head of an engine's rail says it goes back to —
  /// the front, every game.
  String get viewTables => _('viewTables');
  String get tablesLabel => _('tablesLabel');
  String get openToYouLabel => _('openToYouLabel');
  String get backToCategories => _('backToCategories');

  /// The lobby's front (owner, 23 Sep 2026: "give two cards: Teen Patti and
  /// Poker"). [teenPatti] names the Teen Patti engine's card as [poker] names
  /// Poker's, and [teenPattiTableNote] is its one line as [pokerTableNote] is
  /// Poker's; [viewGames] is an engine card's key, which opens its games.
  String get teenPatti => _('teenPatti');
  String get teenPattiTableNote => _('teenPattiTableNote');
  String get viewGames => _('viewGames');

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

  // --- the winning tax (owner, 26–27 Sep 2026): at a table that taxes its
  // winners, the winner of each hand pays a share of their winnings — the rate
  // their LEVEL sets, which falls as their XP climbs, or a badge's where it is
  // lower (a Royal badge: 0%), which XP never reaches. The server takes it and
  // says how much; these only name it. Rates arrive formatted ("17.43%").

  /// The pill on such a table's lobby card and beside its tag on the felt,
  /// with the rate the viewer pays: "17.43% TAX", and "TAX" alone where the
  /// rate is not known.
  String taxPill(String rate) => _('taxPill').replaceFirst('{rate}', rate);
  String get taxPillNoRate => _('taxPillNoRate');

  /// The felt pill's popup title, and the table info popup's row label.
  String get winningTaxTitle => _('winningTaxTitle');
  String get winningTaxLabel => _('winningTaxLabel');

  /// The rows that say where the viewer stands: their level, their XP, the
  /// rate they pay, and the next level up.
  String get yourLevelLabel => _('yourLevelLabel');
  String get xpLabel => _('xpLabel');
  String get yourRateLabel => _('yourRateLabel');
  String get nextLevelLabel => _('nextLevelLabel');

  /// A level named by its number and its name (the server's, with its mark):
  /// "Level 10 · 🌟 Rising Star".
  String levelName(int level, String title) => _(
    'levelName',
  ).replaceFirst('{n}', '$level').replaceFirst('{title}', title);

  /// The Stats drawer's line: "Level 10 · 🌟 Rising Star · 4,180 XP".
  String levelLine(int level, String title, String xp) => _('levelLine')
      .replaceFirst('{n}', '$level')
      .replaceFirst('{title}', title)
      .replaceFirst('{xp}', xp);

  /// What reaches the next level and what it charges, under its name:
  /// "5,200 XP · 17.14%".
  String nextLevelValue(String xp, String rate) =>
      _('nextLevelValue').replaceFirst('{xp}', xp).replaceFirst('{rate}', rate);

  /// At the top of the ladder, where XP leads nowhere further.
  String get topLevelNote => _('topLevelNote');

  /// What the felt pill's popup says the tax is — and, to anybody whose badge
  /// does not set their rate, that climbing the levels lowers it.
  String get winningTaxOnlyWinner => _('winningTaxOnlyWinner');
  String get winningTaxFalls => _('winningTaxFalls');

  /// A taxing table's rule, one bullet: "The winner of each hand pays a share
  /// of the pot as winning tax — 20% at Level 1, less at every level up. A
  /// badge can lower it further." Badges are named as what lowers the rate,
  /// never as something XP leads to (owner, 27 Sep 2026: "Vip is not a level,
  /// it is badge").
  String winningTaxRule(String top, {String? from}) =>
      '${_('ruleWinningTax').replaceFirst('{top}', top)} '
      '${_('ruleWinningTaxBadge')}'
      '${from == null ? '' : ' ${winningTaxFrom(from)}'}';

  /// The winnings a table taxes from (owner, 27 Sep 2026: "30 lakh is the
  /// limit on winning amount not on pot limit"): "No tax on winnings under 30
  /// Lakh." — and, where a table's figures are listed, "on winnings of 30
  /// Lakh or more". [amount] arrives formatted.
  String winningTaxFrom(String amount) =>
      _('winningTaxFrom').replaceFirst('{amount}', amount);
  String taxOnWinningsFrom(String amount) =>
      _('taxOnWinningsFrom').replaceFirst('{amount}', amount);

  /// A badge's validity where it has none (Standard: "standard badge validity
  /// lifetime"), its price where it is 0 ("standard badge 0 ruppes"), and the
  /// rate it brings a holder's down to: "0% winning tax".
  String get badgeLifetime => _('badgeLifetime');
  String get badgeFree => _('badgeFree');
  String badgeTaxLine(String rate) =>
      _('badgeTaxLine').replaceFirst('{rate}', rate);

  /// After a badge is bought: "🂮 Tax Free King is yours until 27/10/2026."
  String badgeBought(String badge, String date) => _(
    'badgeBought',
  ).replaceFirst('{badge}', badge).replaceFirst('{date}', date);

  /// The store's Badges shelf (owner, 27 Sep 2026: "Add a icon in Store to
  /// buy badges, and for all type of royal badges Add a button to contact
  /// support in store"): its key, title and line, and the support question a
  /// badge given by hand asks — its key, the popup's title and body, the
  /// email's subject, and the address to copy where no mail app opens.
  String get storeTabBadges => _('storeTabBadges');
  String get storeBadgesTitle => _('storeBadgesTitle');
  String get storeBadgesBlurb => _('storeBadgesBlurb');
  String get badgeContactSupport => _('badgeContactSupport');
  String badgeContactTitle(String badge) =>
      _('badgeContactTitle').replaceFirst('{badge}', badge);
  String badgeContactBody(String badge) =>
      _('badgeContactBody').replaceFirst('{badge}', badge);
  String badgeMailSubject(String badge) =>
      _('badgeMailSubject').replaceFirst('{badge}', badge);
  String get copyAddress => _('copyAddress');
  String get addressCopied => _('addressCopied');

  /// On the winner's ribbon, with the celebration: "Winning tax −1,360".
  String winnerTaxLine(String tax) =>
      _('winnerTaxLine').replaceFirst('{tax}', tax);

  /// The toast when XP lifts the player a level: "Level up! 🌟 Level 10 ·
  /// Rising Star — your winning tax is now 17.43%." — and, when a badge keeps
  /// the rate they pay below either level's, "Level up! 🌟 Level 10 · Rising
  /// Star" alone.
  String levelUp(String level, String rate) =>
      _('levelUp').replaceFirst('{level}', level).replaceFirst('{rate}', rate);
  String levelUpOnly(String level) =>
      _('levelUpOnly').replaceFirst('{level}', level);

  /// Today's XP against the day's cap — "Today 23 / 50 XP" — and when the
  /// 24-hour window ends: "resets in 5h 12m 3s".
  String xpToday(int xp, int cap) =>
      _('xpToday').replaceFirst('{xp}', '$xp').replaceFirst('{cap}', '$cap');
  String xpResetsIn(String time) =>
      _('xpResetsIn').replaceFirst('{time}', time);

  /// The tax popup's row for today's XP.
  String get todayLabel => _('todayLabel');

  // --- the tax popup in full (owner, 27 Sep 2026: the felt's pill, tapped,
  // "will show everything in detail and it also show all levels and taxes
  // acc to that"; "Vip is not a level, it is badge … the tax will be applied
  // acc to minimum of badge or player level").

  /// The headings: every level of the ladder, the badges there are, and the
  /// viewer's own badges.
  String get allLevelsTitle => _('allLevelsTitle');

  /// The level popup (owner, 27 Sep 2026: "Add one icon in lobby so that user
  /// can see his level, and in that pop up add one tab also for daily xp, one
  /// tab for ladder"): its first tab — the viewer's own level — and its title
  /// when the lobby's level key opens it.
  String get levelTabMine => _('levelTabMine');
  String get yourLevelTitle => _('yourLevelTitle');
  String get badgesTitle => _('badgesTitle');
  String get yourBadgesTitle => _('yourBadgesTitle');

  /// What a screen reader hears for the badge on the lobby's profile picture
  /// (AvatarBadge): "Regular badge".
  String avatarBadgeSemantics(String badge) =>
      _('avatarBadgeSemantics').replaceFirst('{badge}', badge);

  /// The ladder's rate column, and the viewer's own row in it.
  String get taxColumn => _('taxColumn');
  String get levelYou => _('levelYou');

  /// The level's own rate, beside the rate the viewer pays.
  String get levelTaxLabel => _('levelTaxLabel');

  /// The rule the rate follows, and which of the two set it.
  String get winningTaxLowest => _('winningTaxLowest');
  String get rateSetByLevel => _('rateSetByLevel');
  String rateSetByBadge(String badge) =>
      _('rateSetByBadge').replaceFirst('{badge}', badge);

  /// The daily XP (owner, 27 Sep 2026: "Daily XP user can get … After 24
  /// hours this will be reset, so user can claim this again"): its heading,
  /// its sources named by what earns them — "Play 15 active minutes", "Win by
  /// Trail" (the hand's English name, as the table shows it) — the reset, and
  /// what a source already earned in the window says to a screen reader.
  String get xpDailyTitle => _('xpDailyTitle');
  String xpPlayMinutes(int minutes) =>
      _('xpPlayMinutes').replaceFirst('{n}', '$minutes');
  String xpWinBy(String hand) => _('xpWinBy').replaceFirst('{hand}', hand);

  /// The bar at the top of the screen when a daily XP mission is completed
  /// (owner, 27 Sep 2026: "show top notification bar for 5 seconds showing
  /// this is completed and xp increased"): "Win by Pair completed", the XP it
  /// gave ("+1 XP"), and the name for a mission the level ladder has not
  /// described yet.
  String xpMissionDone(String mission) =>
      _('xpMissionDone').replaceFirst('{mission}', mission);
  String xpGained(String xp) => _('xpGained').replaceFirst('{xp}', xp);
  String get xpMissionFallback => _('xpMissionFallback');

  /// Under the bar's level up, when the level changed the winning tax the
  /// player pays: "Winning tax now 19.71%".
  String xpBarTaxNow(String rate) =>
      _('xpBarTaxNow').replaceFirst('{rate}', rate);
  String xpListResets(int hours) =>
      _('xpListResets').replaceFirst('{time}', timeHours(hours));
  String get xpEarned => _('xpEarned');

  /// The day's cap: "Up to 50 XP every 24 hours." — and that nothing earned
  /// ever runs out (owner, 27 Sep 2026: "there is no validity on player
  /// level", "XP also never expire once user has been granted").
  String xpDailyCap(int cap, int hours) => _(
    'xpDailyCap',
  ).replaceFirst('{cap}', '$cap').replaceFirst('{time}', timeHours(hours));
  String get xpNeverExpires => _('xpNeverExpires');

  // --- the level screen (the lobby's level key, polished 27 Sep 2026).

  /// A level by its number alone: "Level 10".
  String levelNumber(int n) => _('levelNumber').replaceFirst('{n}', '$n');

  /// XP against a goal, "23 / 100 XP", and what is left to the next level:
  /// "77 XP to 🔰 Rookie". Figures arrive formatted.
  String xpOf(String xp, String max) =>
      _('xpOf').replaceFirst('{xp}', xp).replaceFirst('{max}', max);
  String xpToNext(String xp, String title) =>
      _('xpToNext').replaceFirst('{xp}', xp).replaceFirst('{title}', title);

  /// The next level, the XP that reaches it and its rate: "Next: Level 2 ·
  /// 🔰 Rookie · 100 XP · 19.71% tax".
  String levelNextLine(String level, String xp, String rate) =>
      _('levelNextLine')
          .replaceFirst('{level}', level)
          .replaceFirst('{xp}', xp)
          .replaceFirst('{rate}', rate);

  /// How the tax works, a line each: only the winner pays, on net winnings;
  /// what net winnings are; and that a badge can lower it further.
  String get taxNoteWinner => _('taxNoteWinner');
  String get taxNoteNet => _('taxNoteNet');
  String get taxNoteBadge => _('taxNoteBadge');

  /// A held badge whose grant is running.
  String get badgeActive => _('badgeActive');

  /// The top of the ladder, on the level's hero.
  String get levelMax => _('levelMax');

  /// The lobby top bar's level, short: "Lv 10" (owner, 27 Sep 2026: "In the
  /// Lobby on Top show current level of player and xp progress bar").
  String levelShort(int n) => _('levelShort').replaceFirst('{n}', '$n');

  /// What a screen reader says of the top bar's level:
  /// "Level 10, 4,180 of 5,200 XP" — and at the top of the ladder
  /// "Level 50, 20 Lakh XP, top level". Figures arrive formatted.
  String levelBarSemantics(int n, String xp, String max) =>
      _('levelBarSemantics')
          .replaceFirst('{n}', '$n')
          .replaceFirst('{xp}', xp)
          .replaceFirst('{max}', max);
  String levelBarTopSemantics(int n, String xp) => _(
    'levelBarTopSemantics',
  ).replaceFirst('{n}', '$n').replaceFirst('{xp}', xp);

  /// The heading over the sentences that say how the tax works.
  String get levelHowTax => _('levelHowTax');

  /// A badge the viewer holds: the one that sets their rate, one about to run
  /// out ("Expires in 5 hours"), one that has run out while the screen was
  /// open, and — in the catalogue — one that is theirs.
  String get badgeSetsRate => _('badgeSetsRate');
  String badgeExpiresIn(String time) =>
      _('badgeExpiresIn').replaceFirst('{time}', time);
  String get badgeExpired => _('badgeExpired');
  String get badgeYours => _('badgeYours');

  /// Under a player who holds only Regular: what the Royal badges do, and the
  /// key to the store's Badges shelf.
  String badgeRoyalHint(String rate) =>
      _('badgeRoyalHint').replaceFirst('{rate}', rate);
  String get badgeSeeStore => _('badgeSeeStore');

  /// Under the badge catalogue: a badge is never an XP goal.
  String get badgesBesideLevel => _('badgesBesideLevel');

  /// The daily XP's summary: what today's window has earned, the whole day
  /// earned, when it resets (capitalised, on its own), and a day not yet
  /// begun.
  String get xpEarnedToday => _('xpEarnedToday');
  String get xpDailyComplete => _('xpDailyComplete');
  String get xpDailyCompleteNote => _('xpDailyCompleteNote');
  String xpResetsInCap(String time) =>
      _('xpResetsInCap').replaceFirst('{time}', time);
  String get xpWindowIdle => _('xpWindowIdle');

  /// The two groups of daily XP: the play-time milestones — which add up, each
  /// paid once a day as play reaches it — and the winning hands.
  String get xpPlayTimeTitle => _('xpPlayTimeTitle');
  String get xpPlayTimeNote => _('xpPlayTimeNote');
  String xpMinutes(int n) => _('xpMinutes').replaceFirst('{n}', '$n');
  String get xpWinHandsTitle => _('xpWinHandsTitle');
  String get xpWinHandsNote => _('xpWinHandsNote');

  /// The ladder: the level after the viewer's, and its first column's name.
  String get levelNextTag => _('levelNextTag');
  String get levelColumn => _('levelColumn');

  /// A day as the countdowns abbreviate it ("29d 14h left"), beside
  /// [unitHourShort] and [unitMinuteShort].
  String get unitDayShort => _('unitDayShort');

  /// A badge of the catalogue the viewer does not hold.
  String get badgeAvailable => _('badgeAvailable');

  /// A daily XP source that is neither play time nor a winning hand.
  String get xpOtherTitle => _('xpOtherTitle');

  /// The ONE_TIME missions (owner, 28 Sep 2026: "One-time missions are
  /// permanent missions that a player can complete only once"), under the
  /// daily XP: the section, its line, how many are done ("3 / 12
  /// completed"), a completed mission's tag, and what each asks in the
  /// player's words — "Play 10 hands", "Win 1 Poker hand", "Play 5 different
  /// games", {game} a game's name. A mission's title ("First Hand") is the
  /// server's, shown as it wrote it, as a level's title is.
  String get xpOneTimeTitle => _('xpOneTimeTitle');

  /// The level screen's fourth tab, beside Daily XP (owner, 28 Sep 2026: "the
  /// tab in UI one Time XP, on the side of Daily XP"), and what it says when
  /// the server offers no one-time mission (an older one, or all retired).
  String get xpOneTimeTab => _('xpOneTimeTab');
  String get xpOneTimeNone => _('xpOneTimeNone');
  String get xpOneTimeNote => _('xpOneTimeNote');
  String xpOneTimeDone(int n, int of) =>
      _('xpOneTimeDone').replaceFirst('{n}', '$n').replaceFirst('{of}', '$of');
  String get xpMissionCompleted => _('xpMissionCompleted');
  String xpMissionPlayHands(int n) => n == 1
      ? _('xpMissionPlayHand1')
      : _('xpMissionPlayHands').replaceFirst('{n}', '$n');
  String xpMissionWinHands(int n) => n == 1
      ? _('xpMissionWinHand1')
      : _('xpMissionWinHands').replaceFirst('{n}', '$n');
  String xpMissionPlayGameHands(int n, String game) =>
      (n == 1
              ? _('xpMissionPlayGameHand1')
              : _('xpMissionPlayGameHands').replaceFirst('{n}', '$n'))
          .replaceFirst('{game}', game);
  String xpMissionWinGameHands(int n, String game) =>
      (n == 1
              ? _('xpMissionWinGameHand1')
              : _('xpMissionWinGameHands').replaceFirst('{n}', '$n'))
          .replaceFirst('{game}', game);
  String xpMissionGames(int n) => _('xpMissionGames').replaceFirst('{n}', '$n');
  String xpMissionGamesIn(int n, String game) => _(
    'xpMissionGamesIn',
  ).replaceFirst('{n}', '$n').replaceFirst('{game}', game);
  String xpMissionVariations(int n) =>
      _('xpMissionVariations').replaceFirst('{n}', '$n');

  /// A badge in the catalogue: Standard is everyone's; the others last a
  /// validity from the grant — in years where it is whole years ("Lasts 5
  /// years", owner, 27 Sep 2026: "validity keep 5 years"), else in days.
  String get badgeEveryone => _('badgeEveryone');
  String badgeLasts(int days) => _('badgeLasts').replaceFirst(
    '{time}',
    days >= 365 && days % 365 == 0 ? timeYears(days ~/ 365) : timeDays(days),
  );

  /// When a badge the viewer holds runs out, where that is a month or more
  /// away: "Until 26/09/2031".
  String badgeUntil(String date) =>
      _('badgeUntil').replaceFirst('{date}', date);

  /// When the ladder could not be read.
  String get levelsUnavailable => _('levelsUnavailable');
  String get variationChooseTitle => _('variationChooseTitle');

  // 5-Card Teen Patti: the player chooses which three of their five play
  // (owner, 19 Sep 2026).
  String get pickTitle => _('pickTitle');
  String get pickHint => _('pickHint');
  String get pickConfirm => _('pickConfirm');
  String get pickThreeCards => _('pickThreeCards');
  String get pickWasBest => _('pickWasBest');
  String get pickNotBest => _('pickNotBest');
  String get pickTimedOut => _('pickTimedOut');
  String get pickYouPlayed => _('pickYouPlayed');
  String get pickTheBest => _('pickTheBest');

  /// "Ravi is choosing cards…", for everyone waiting on a 5-Card chooser who
  /// is also on turn (owner, 19 Sep 2026).
  String pickChoosing(String name) =>
      _('pickChoosing').replaceAll('{name}', name);

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

  /// The same two as row titles in the table menu, beside "Your chips":
  /// capitalised where the script has case.
  String get blindsTitle => _('blindsTitle');
  String get anteTitle => _('anteTitle');
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

  /// Enough of each game to play it: the streets in order, that a bet names
  /// the total for the street, and 3-Card Poker's second bet.
  String get rulePokerStreets => _('rulePokerStreets');
  String get rulePokerBetTo => _('rulePokerBetTo');
  String get rulePokerDrawStreets => _('rulePokerDrawStreets');
  String get rulePokerPlayBet => _('rulePokerPlayBet');
  String get rulePokerThreeCardRuns => _('rulePokerThreeCardRuns');

  /// The ranking shown on ONE poker table's own sheet: five cards at
  /// Hold'em, Omaha and 5-Card Draw, three at 3-Card Poker.
  String get pokerTableRankingTitle => _('pokerTableRankingTitle');
  String get pokerTableRankingIntro => _('pokerTableRankingIntro');
  String get pokerThreeCardRankingIntro => _('pokerThreeCardRankingIntro');

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

  /// A move refused while the player's own sideshow request still waits for
  /// its answer (`sideshow_pending`, 24 Sep 2026).
  String get sideshowPendingRefusal => _('sideshowPendingRefusal');

  /// Sideshow, Force Sideshow, Missile or Show refused while a player is still
  /// choosing their three cards under 5-Card Teen Patti (`pick_pending`,
  /// 24 Sep 2026).
  String get pickPendingRefusal => _('pickPendingRefusal');
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
  // The table's warning after a missed turn (owner, 27 Sep 2026;
  // widgets/missed_turns_notice.dart): what happened, then how many of the
  // table's allowance are gone — or, one short of the kick, the last warning.
  String get autoPacked => _('autoPacked');
  String get missedYourTurn => _('missedYourTurn');
  String missedTurnsCount(int n, int max) =>
      _('missedTurnsCount').replaceAll('{n}', '$n').replaceAll('{max}', '$max');
  String get lastWarning => _('lastWarning');
  String get missOneMore => _('missOneMore');
  String get resumingTable => _('resumingTable');

  /// Under the game's loader, wherever one is shown (owner, 28 Sep 2026:
  /// "below text also please wait...").
  String get pleaseWait => _('pleaseWait');
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

  /// The block control in the chat drawer (owner, 22 Sep 2026). Blocking is
  /// this viewer's own view of one table for one sitting — no report, no
  /// server, nothing kept. Since 24 Sep 2026 it is a page of the drawer with
  /// a key per player and no question asked (owner: "do not show pop up"),
  /// so the confirmation's title and body and the chat page's "Blocked" label
  /// went with the dialog and the row that carried them.
  String get block => _('block');
  String get unblock => _('unblock');
  String get blockPlayersTitle => _('blockPlayersTitle');
  String get blockNobody => _('blockNobody');
  String get saySomething => _('saySomething');
  String get tableMenu => _('tableMenu');

  // --- quick messages: set lines a player sends from the table's rail
  String get quickMessagesTitle => _('quickMessagesTitle');
  String get quickMessagesTip => _('quickMessagesTip');
  String get quickReorderHint => _('quickReorderHint');
  String get quickAddMessage => _('quickAddMessage');
  String get quickCustomHint => _('quickCustomHint');
  String get quickCustomDuplicate => _('quickCustomDuplicate');
  String get quickCustomFull => _('quickCustomFull');
  String get quickDeleteMessage => _('quickDeleteMessage');
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

  /// Over the two pills of an unlock or top-up question: what it costs, and
  /// what the player holds of that wallet (28 Sep 2026).
  String get priceLabel => _('priceLabel');
  String get youHaveLabel => _('youHaveLabel');
  String unlockBody(String name, String cost) =>
      _('unlockBody').replaceAll('{name}', name).replaceAll('{cost}', cost);

  /// The word on a premium picture this player has already paid for.
  String get pictureUnlocked => _('pictureUnlocked');

  /// The word a shelf tile's badge says on a picture the player can put on
  /// now — free, or bought and still running (the store polish, 26 Sep 2026).
  /// The picture being worn says [wearing], as the store's head does, and the
  /// laid table picture [tableInUse].
  String get pictureOwned => _('pictureOwned');

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

  /// Months and years, for how long two players have been friends.
  String timeMonths(int n) =>
      _(n == 1 ? 'timeMonth' : 'timeMonths').replaceAll('{n}', '$n');
  String timeYears(int n) =>
      _(n == 1 ? 'timeYear' : 'timeYears').replaceAll('{n}', '$n');

  /// How long two players have been friends, [since] they became friends (a
  /// duration, never negative): "Friends for 3 days", in the largest whole
  /// unit — minutes under an hour, hours under a day, days under 30, months
  /// (of 30 days) under a year (of 365), then years; "Friends since just now"
  /// under a minute. The player drawer's head (owner, 26 Sep 2026: "show each
  /// other at the top how long they are friends in time").
  String friendsFor(Duration since) {
    final d = since.isNegative ? Duration.zero : since;
    if (d.inMinutes < 1) return _('friendsJustNow');
    final time = d.inHours < 1
        ? timeMinutes(d.inMinutes)
        : d.inDays < 1
        ? timeHours(d.inHours)
        : d.inDays < 30
        ? timeDays(d.inDays)
        : d.inDays < 365
        ? timeMonths(d.inDays ~/ 30)
        : timeYears(d.inDays ~/ 365);
    return _('friendsFor').replaceAll('{time}', time);
  }

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

  /// The popup a disabled account gets (users.is_active; owner, 26 Sep 2026):
  /// at sign-in, on a restored session, and when a table refuses it.
  String get accountDisabledTitle => _('accountDisabledTitle');
  String get accountDisabledBody => _('accountDisabledBody');
  String get sessionReplacedTitle => _('sessionReplacedTitle');

  /// The name under the player's own sign-in photo on the picture shelf:
  /// "Google photo" for a Google account, "Your photo" for any other.
  String providerPhoto(String provider) =>
      _(provider == 'google' ? 'googlePhoto' : 'ownPhoto');
  String get sessionReplacedBody => _('sessionReplacedBody');

  // --- the app version gate (owner, 28 Sep 2026): Force Update, Soft Update,
  // Maintenance. The screens show an operator's own message verbatim when the
  // server sends one, and these words otherwise.
  String get updateTitle => _('updateTitle');
  String get updateBody => _('updateBody');
  String get updateNow => _('updateNow');
  String get updateOpenStore => _('updateOpenStore');
  String get updateOpenAppStore => _('updateOpenAppStore');
  String get updateFailed => _('updateFailed');
  String updateVersionLine(String installed, String required) => _(
    'updateVersionLine',
  ).replaceAll('{installed}', installed).replaceAll('{required}', required);
  String get updateStoreUnavailable => _('updateStoreUnavailable');
  String get softUpdateTitle => _('softUpdateTitle');
  String get softUpdateBody => _('softUpdateBody');
  String get softUpdateLater => _('softUpdateLater');
  String get maintenanceTitle => _('maintenanceTitle');
  String get maintenanceBody => _('maintenanceBody');
  String get maintenanceRetry => _('maintenanceRetry');
  String get purchaseNotLaunched => _('purchaseNotLaunched');

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
      'statsAll': 'All',
      'handsHeld': 'Hands held',
      'variationsPlayed': 'Variations played',
      'statsPlayed': 'Played',
      'statsWon': 'Won',
      'statsNoVariations': 'No variation hands yet',
      'statsPerformance': 'Performance',
      'statsAllGames': 'All Games',
      'statsVariations': 'Variations',
      'statsScopeLabel': 'Statistics for',
      'statsHandResults': 'Hand results',
      'statsNoHandResults': 'No hand results yet',
      'statsNoVariationGames': 'No variation games played yet',
      'statsHandResultsHint': 'Choose Teen Patti or Variations to see these',
      'statsVariationsHint': 'Choose Variations to see these',
      'luckyDrawChip': 'LUCKY DRAW',
      'luckyDrawTitle': 'Lucky Draw',
      'luckySpinReady': 'Spin now',
      'luckySpinNow': 'SPIN NOW',
      'luckySpinning': 'SPINNING…',
      'luckyNextSpin': 'NEXT SPIN',
      'luckyFreeSpin': 'FREE SPIN',
      'luckyNextFreeSpin': 'NEXT FREE SPIN',
      'luckyEvery': 'One free spin every {time}.',
      'rewardsChip': 'REWARDS',
      'rewardsTitle': 'Daily Rewards',
      'rewardsCollect': 'Collect now',
      'rewardsCollected': 'Collected today',
      'rewardsCollectedTitle': 'Daily rewards collected!',
      'streakDayOne': '1 day streak',
      'streakDays': '{n} day streak',
      'streakStart': 'Start your streak today',
      'calendarDayReward': 'Day {n} reward',
      'rewardModeStreak': 'LOGIN STREAK',
      'rewardModeCalendar': 'CALENDAR',
      'rewardStreakHint':
          'Log in every day to climb the ladder. Miss a day and the streak starts again from Day 1.',
      'rewardStreakHintNoReset':
          'Log in every day to climb the ladder. A missed day is simply skipped.',
      'rewardCalendarWeekHint':
          'One reward for each day of the week. A missed day is missed; the rest still wait for you.',
      'rewardCalendarMonthHint':
          'One reward for each day of the month. A missed day is missed; the rest still wait for you.',
      'rewardNext': 'Next reward',
      'rewardDay': 'Day {n}',
      'rewardToday': 'Today',
      'rewardTileClaimed': 'Collected',
      'rewardTileLocked': 'Locked',
      'rewardTileMissed': 'Missed',
      'rewardNone': 'No rewards are running right now.',
      'rewardLoadFailed': 'Could not load the rewards.',
      'rewardLobbyOnly': 'Collect your rewards from the lobby, not at a table.',
      'rewardNothing': 'No reward',
      'rewardAlreadyOwned': 'already yours',
      'rewardEmojiName': '{name} emoji',
      'rewardPictureName': '{name} picture',
      'rewardTablePictureName': '{name} table picture',
      'rewardBadgeName': '{name} badge',
      'rewardBadgeDays': '{name} badge · {n} days',
      'rewardProgramWeeklyLogin': 'Weekly Login Streak',
      'rewardProgramMonthlyLogin': 'Monthly Login Streak',
      'rewardProgramWeeklyCalendar': 'Weekly Calendar Rewards',
      'rewardProgramMonthlyCalendar': 'Monthly Calendar Rewards',
      'todaysReward': 'Today\'s reward: {prize}',
      'rewardsAlso': 'Also: {list}',
      'todaysRewardTitle': 'Today\'s reward',
      'continueKey': 'Continue',
      'weeklyFinal': 'FINAL',
      'weekday1': 'Mon',
      'weekday2': 'Tue',
      'weekday3': 'Wed',
      'weekday4': 'Thu',
      'weekday5': 'Fri',
      'weekday6': 'Sat',
      'weekday7': 'Sun',
      'luckyPrizes': 'PRIZES ON THE WHEEL',
      'luckyNoPrize': 'No prize',
      'luckyCongrats': 'Congratulations!',
      'luckyYouWon': 'You won',
      'luckyNothingTitle': 'Better luck next time!',
      'luckyNothingBody': 'The wheel stopped on the empty slot.',
      'luckyAlreadyOwned': 'It is already yours, so nothing new was unlocked.',
      'luckyPictureFor': 'Yours for {time}',
      'luckyWearNow': 'Wear it',
      'luckyLayNow': 'Use it',
      'luckyProfilePicture': 'Profile picture',
      'luckyTablePicture': 'Table picture',
      'luckyClosed': 'The Lucky Draw is closed right now.',
      'luckyLoadFailed': 'The Lucky Draw could not be loaded.',
      'luckyRetry': 'Try again',
      'luckyLobbyOnly': 'Spin the Lucky Draw from the lobby.',
      'luckyNotReady': 'Your next spin is not ready yet.',
      'countMissileOne': '1 missile',
      'countMissiles': '{n} missiles',
      'welcomeAdded': 'Welcome! Added to your account: {items}',
      'welcomePlain': 'Welcome to King Teen Patti!',
      'countPictureOne': '1 picture',
      'countPictures': '{n} pictures',
      'countTablePictureOne': '1 table picture',
      'countTablePictures': '{n} table pictures',
      'countEmojiOne': '1 emoji',
      'countEmojis': '{n} emojis',
      'rewardCollected': 'Reward collected!',
      'rewardPurchased': 'The chips are in your wallet. Good luck.',
      'rewardDiamondsPurchased':
          'The diamonds are in your wallet. Trade them for missiles.',
      'tapToClose': 'Tap to close',
      'buyChips': 'Buy chips',
      'shop': 'Shop',
      'comingSoon': 'Coming soon',
      'updateTitle': 'Update required',
      'updateBody':
          'A new version of King Teen Patti is required to continue playing.',
      'updateNow': 'Update now',
      'updateOpenStore': 'Open Play Store',
      'updateOpenAppStore': 'Open App Store',
      'updateFailed': 'The update did not finish. Please try again.',
      // The app version gate (owner, 28 Sep 2026).
      'updateVersionLine': 'Your version {installed} · Required {required}',
      'updateStoreUnavailable':
          'The store could not be opened. Please update King Teen Patti from your app store.',
      'softUpdateTitle': 'New version available',
      'softUpdateBody': 'A newer version of King Teen Patti is available.',
      'softUpdateLater': 'Later',
      'maintenanceTitle': 'Under maintenance',
      'maintenanceBody':
          'King Teen Patti is temporarily unavailable. Please try again later.',
      'maintenanceRetry': 'Try again',
      'purchaseNotLaunched': 'The purchase did not go through.',
      'storeTitle': 'Chip Store',
      'storeBlurb': 'The bigger the pack, the bigger the bonus.',
      'storeTabChips': 'Chips',
      'storeTabPictures': 'Pictures',
      'storeTabAnimated': 'Animated',
      'storePicturesBlurb': 'Unlock a picture with chips, hammers or diamonds.',
      'storeAnimatedBlurb':
          'Unlock an animated picture with hammers or diamonds.',
      'storeTabTables': 'Tables',
      'storeTablesTitle': 'Table Pictures',
      'storeTablesBlurb': 'Dress your table — one look for day, one for night.',
      'tableDefault': 'Flowing chips',
      'tableDefaultHint': 'The default background',
      'tableInUse': 'In use',
      'unlockTableTitle': 'Unlock this table?',
      'unlockTableBody': '{name} costs {price}. Unlock it and use it now?',
      'unlockTableRentBody':
          '{name} costs {price} and dresses your table for {time}. Unlock it and use it now?',
      'tableChipsLobbyOnly':
          'You can only buy a chip-priced table picture in the lobby.',
      'priceChips': '{cost} chips',
      'priceDiamonds': '{cost} diamond{s}',
      'priceHammers': '{cost} hammers',
      'priceHammerOne': '1 hammer',
      'priceDiamondOne': '1 diamond',
      'tablePokerNote':
          'Poker tables show no table picture — it will show at your next Teen Patti table.',
      // Emojis (owner, 26 Sep 2026).
      'storeTabEmojis': 'Emojis',
      'storeEmojisTitle': 'Emojis',
      'storeEmojisBlurb': 'Animated emojis to send to the whole table.',
      'storeTabBadges': 'Badges',
      'storeBadgesTitle': 'Badges',
      'storeBadgesBlurb':
          'A badge lowers the winning tax you pay while it lasts.',
      'badgeContactSupport': 'Contact support',
      'badgeContactTitle': 'Get {badge}',
      'badgeContactBody':
          '{badge} is given by our team. Write to us and we will help you get it.',
      'badgeMailSubject': 'I would like the {badge} badge',
      'copyAddress': 'Copy address',
      'addressCopied': 'Address copied',
      'emojiShelfEmpty': 'No emojis yet.',
      'unlockEmojiTitle': 'Unlock this emoji?',
      'unlockEmojiBody': '{name} costs {price}. Unlock it now?',
      'unlockEmojiRentBody':
          '{name} costs {price} and is yours for {time}. Unlock it now?',
      'emojiChipsLobbyOnly':
          'You can only buy a chip-priced emoji in the lobby.',
      'emojiOwnedNote':
          'This emoji is yours — send it with the emoji key at a table.',
      'tableEmojis': 'Emojis',
      'emojiSendHint': 'Tap an emoji to send it to the table.',
      'emojiUnlockMore': 'Tap one to unlock it',
      'emojiNoneOwned': 'You have no emojis yet — unlock one below.',
      'emojiSentBy': '{name} sent {emoji}',
      'emojiLockedRefusal': 'Unlock this emoji in the store first.',
      'emojiUnknownRefusal': 'That emoji does not exist.',
      'emojiRetiredRefusal': 'That emoji is no longer available.',
      'emojiUnaffordableRefusal':
          'You do not have enough to unlock this emoji.',
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
      'forceSideshowTooLate':
          'Too late — that sideshow is no longer open. No hammer was spent.',
      'settings': 'Settings',
      'language': 'Language',
      'settingsSubtitle': 'Personalize your game experience',
      'settingsProfile': 'Profile',
      'settingsGameExperience': 'Game experience',
      'settingsAccount': 'Account',
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
      'deleteAccount': 'Delete my account',
      'deleteAccountTitle': 'Delete your account?',
      'deleteAccountBody':
          'This erases your name, picture, statistics and every chip you hold, including chips you paid for. It cannot be undone, and nothing can be restored to a new account.',
      'deleteAccountSeated': 'Leave the table before deleting your account.',
      'deleteAccountConfirm': 'Delete permanently',
      'useProviderPicture': 'Use my Google picture',
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
      'teenPatti': 'TEEN PATTI',
      'teenPattiTableNote': 'Seen, Blind and Variation tables',
      'viewGames': 'View games',
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
      'taxPill': '{rate} TAX',
      'taxPillNoRate': 'TAX',
      'winningTaxTitle': 'Winning Tax',
      'winningTaxLabel': 'winning tax',
      'yourLevelLabel': 'your level',
      'xpLabel': 'XP',
      'yourRateLabel': 'your rate',
      'nextLevelLabel': 'next level',
      'levelName': 'Level {n} · {title}',
      'levelLine': 'Level {n} · {title} · {xp} XP',
      'nextLevelValue': '{xp} XP · {rate}',
      'topLevelNote': 'This is the top level.',
      'winningTaxOnlyWinner':
          'Only the winner of each hand pays winning tax, on what they win — the pot less their own chips.',
      'winningTaxFalls': 'The higher your level, the less you pay.',
      'ruleWinningTax':
          'The winner of each hand pays winning tax on what they win — the pot less their own chips — {top} at Level 1, less at every level up.',
      'winnerTaxLine': 'Winning tax −{tax}',
      'levelUp': 'Level up! {level} — your winning tax is now {rate}.',
      'xpToday': 'Today {xp} / {cap} XP',
      'xpResetsIn': 'resets in {time}',
      'todayLabel': 'today',
      'levelUpOnly': 'Level up! {level}',
      'allLevelsTitle': 'All levels',
      'levelTabMine': 'My level',
      'yourLevelTitle': 'Your level',
      'badgesTitle': 'Badges',
      'yourBadgesTitle': 'Your badges',
      'avatarBadgeSemantics': '{badge} badge',
      'taxColumn': 'Tax',
      'levelYou': 'You',
      'levelTaxLabel': 'level tax',
      'winningTaxLowest':
          'You pay the lowest of your level\'s rate and your badges\'.',
      'rateSetByLevel': 'Set by your level',
      'rateSetByBadge': 'Set by your {badge} badge',
      'xpDailyTitle': 'Daily XP',
      'xpPlayMinutes': 'Play {n} active minutes',
      'xpWinBy': 'Win by {hand}',
      'xpMissionDone': '{mission} completed',
      'xpGained': '+{xp} XP',
      'xpMissionFallback': 'Daily XP mission',
      'xpBarTaxNow': 'Winning tax now {rate}',
      'xpListResets': 'The list resets every {time}.',
      'xpEarned': 'Earned',
      'xpDailyCap': 'Up to {cap} XP every {time}.',
      'xpNeverExpires': 'XP and levels never expire.',
      'levelNumber': 'Level {n}',
      'xpOf': '{xp} / {max} XP',
      'xpToNext': '{xp} XP to {title}',
      'levelNextLine': 'Next: {level} · {xp} XP · {rate} tax',
      'taxNoteWinner':
          'Only the winner of a hand pays Winning Tax, on their net winnings.',
      'taxNoteNet': 'Net winnings = the pot − your own chips in it.',
      'taxNoteBadge': 'An active badge can lower your tax further.',
      'badgeActive': 'Active',
      'levelMax': 'MAX LEVEL',
      'levelShort': 'Lv {n}',
      'levelBarSemantics': 'Level {n}, {xp} of {max} XP',
      'levelBarTopSemantics': 'Level {n}, {xp} XP, top level',
      'levelHowTax': 'How Winning Tax works',
      'badgeSetsRate': 'Sets your rate',
      'badgeExpiresIn': 'Expires in {time}',
      'badgeExpired': 'Expired',
      'badgeYours': 'Yours',
      'badgeRoyalHint': 'Royal badges bring your Winning Tax down to {rate}.',
      'badgeSeeStore': 'See badges',
      'badgesBesideLevel':
          'Badges are held beside your level; XP never earns one.',
      'xpEarnedToday': 'Earned today',
      'xpDailyComplete': 'Daily XP Complete',
      'xpDailyCompleteNote':
          'You have earned every daily XP. More after the reset.',
      'xpResetsInCap': 'Resets in {time}',
      'xpWindowIdle': 'Your day starts with your next hand.',
      'xpPlayTimeTitle': 'Play time',
      'xpPlayTimeNote':
          'Each milestone gives its XP once a day as your active play reaches it, and they add up.',
      'xpMinutes': '{n} min',
      'xpWinHandsTitle': 'Winning hands',
      'xpWinHandsNote': 'Win a hand with each of these for its XP, once a day.',
      'levelNextTag': 'Next',
      'levelColumn': 'Level',
      'unitDayShort': 'd',
      'badgeAvailable': 'Available',
      'xpOtherTitle': 'More ways to earn XP',
      'xpOneTimeTitle': 'One-Time missions',
      'xpOneTimeNote': 'Each gives its XP once, for good. They never reset.',
      'xpOneTimeDone': '{n} / {of} completed',
      'xpOneTimeTab': 'One-Time XP',
      'xpOneTimeNone': 'No one-time missions right now.',
      'xpMissionCompleted': 'Completed',
      'xpMissionPlayHand1': 'Play 1 hand',
      'xpMissionPlayHands': 'Play {n} hands',
      'xpMissionWinHand1': 'Win 1 hand',
      'xpMissionWinHands': 'Win {n} hands',
      'xpMissionPlayGameHand1': 'Play 1 {game} hand',
      'xpMissionPlayGameHands': 'Play {n} {game} hands',
      'xpMissionWinGameHand1': 'Win 1 {game} hand',
      'xpMissionWinGameHands': 'Win {n} {game} hands',
      'xpMissionGames': 'Play {n} different games',
      'xpMissionGamesIn': 'Play {n} different {game} games',
      'xpMissionVariations': 'Play {n} different variations',
      'badgeUntil': 'Until {date}',
      'badgeEveryone': 'Everyone',
      'badgeLasts': 'Lasts {time}',
      'levelsUnavailable': 'The levels could not be loaded.',
      'ruleWinningTaxBadge': 'A badge can lower it further.',
      'winningTaxFrom': 'No tax on winnings under {amount}.',
      'taxOnWinningsFrom': 'on winnings of {amount} or more',
      'badgeLifetime': 'Lifetime',
      'badgeFree': 'Free',
      'badgeTaxLine': '{rate} Winning Tax',
      'badgeBought': '{badge} is yours until {date}.',
      'variationRulesIntro':
          'The first player to act has 10 seconds to choose how the hand is decided; if they do not, it is Muflis. A wild card counts as whichever card makes your hand best. Other players\' chips are hidden and the pot has no limit.',
      'variationChooseTitle': 'Choose Variation',
      'pickTitle': 'Choose your three',
      'pickHint': 'Tap three of your five cards to play',
      'pickConfirm': 'Play these three',
      'pickThreeCards': 'Choose exactly three of your own cards',
      'pickWasBest': 'You played the best combination',
      'pickNotBest': 'You played this. The best was:',
      'pickTimedOut': 'Time ran out — your first three were played',
      'pickYouPlayed': 'You played',
      'pickTheBest': 'Best',
      'pickChoosing': '{name} is choosing cards…',
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
      'sideshowPendingRefusal': 'Wait for the sideshow answer first',
      'pickPendingRefusal':
          'Wait a moment: a player is still choosing their three cards',
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
      'autoPacked': 'You missed your turn — auto-packed',
      'missedYourTurn': 'You missed your turn',
      'lastWarning': 'Last warning',
      'missOneMore': 'One more missed turn and you leave the table',
      'missedTurnsCount': 'Missed turns: {n} of {max}',
      'resumingTable': 'Returning to your table…',
      'pleaseWait': 'Please wait...',
      'welcomeBack': "Welcome back — you're back at your table.",
      'appVersion': 'App version',
      'tableLost': 'You lost your seat while you were away.',
      'notConnected': 'No connection. That did not go through.',
      'reconnecting': 'Connection lost. Reconnecting…',
      'kickedNoChips': "You don't have enough chips to stay at this table.",
      'kickedIdle': 'You left the table after {n} missed turns in a row.',
      'leaveStakeStays': 'Your stake stays in the pot',
      'winner': 'Winner',
      'tableChat': 'Table chat',
      'block': 'Block',
      'unblock': 'Unblock',
      'blockPlayersTitle': 'Block players',
      'blockNobody': 'Nobody else is at the table yet.',
      'saySomething': 'Say something…',
      'tableMenu': 'Table menu',
      // The panel's own title and its key's tooltip. The owner gave only the
      // ten lines below, so this wording is ours and free to change.
      'quickMessagesTitle': 'Quick messages',
      'quickMessagesTip': 'Send a quick message',
      'quickReorderHint': 'Hold and drag to reorder',
      'quickAddMessage': 'Add message',
      'quickCustomHint': 'Type your message',
      'quickCustomDuplicate': 'That message is already in your list.',
      'quickCustomFull': 'You can save up to 10 messages of your own.',
      'quickDeleteMessage': 'Delete message',
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
      'priceLabel': 'Price',
      'youHaveLabel': 'You have',
      'unlockBody': '{name} costs {cost} chips. Unlock it and wear it now?',
      'unlockBodyDiamond':
          '{name} costs {cost} diamond{s}. Unlock it and wear it now?',
      'pictureUnlocked': 'Unlocked',
      'pictureOwned': 'Owned',
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
      'timeMonth': '{n} month',
      'timeMonths': '{n} months',
      'timeYear': '{n} year',
      'timeYears': '{n} years',
      'friendsFor': 'Friends for {time}',
      'friendsJustNow': 'Friends since just now',
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
      'accountDisabledTitle': 'Account disabled',
      'accountDisabledBody':
          'Your account is disabled. Please contact support.',
      'googlePhoto': 'Google photo',
      'ownPhoto': 'Your photo',
      'sessionReplacedTitle': 'Signed in on another device',
      'sessionReplacedBody':
          'Someone has signed in to your account on another device, so you have been signed out here. Sign in again to play on this phone — the other device will then be signed out.',
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
      'useSocialPicture': 'Use my Google picture',
      'guestNoSocial': 'Sign in with Google to use your own photo.',

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
      'blindsTitle': 'Blinds',
      'anteTitle': 'Ante',
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
      'rulePokerStreets':
          'Betting runs pre-flop, then again on the flop, the turn and the '
          'river',
      'rulePokerBetTo':
          'A bet or a raise names the TOTAL you want in for this street, not '
          'the amount on top of it',
      'rulePokerDrawStreets': 'Bet once before the draw and once after it',
      'rulePokerPlayBet':
          'Playing costs a second bet the size of the ante; folding leaves '
          'your ante with the house',
      'pokerTableRankingTitle': 'What beats what here',
      'pokerTableRankingIntro':
          'Your hand is the best five cards you can make, ranked like this.',
      'pokerThreeCardRankingIntro':
          'Three cards each, on their own ladder — not the five-card order, '
          'and not Teen Patti\'s.',
      'rulePokerThreeCardRuns': 'A-K-Q is the best run and A-2-3 the lowest',
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
      // Friends (owner, 26 Sep 2026)
      'friends': 'Friends',
      'friendsOnlineCount': '{n} online',
      'friendRequestWaiting': '1 new friend request',
      'friendRequestsWaiting': '{n} new friend requests',
      'yourPlayerId': 'Your Player ID',
      'copyId': 'Copy',
      'idCopied': 'Copied',
      'addFriend': 'Add Friend',
      'friendRequests': 'Friend Requests',
      'noFriendRequests': 'No Friend Requests',
      'noFriendsTitle': 'No Friends Yet',
      'noFriendsBody': 'Add friends using their Player ID.',
      'friendsLoadFailed': 'Could not load friends.',
      'friendsRetry': 'Retry',
      'friendAccept': 'Accept',
      'friendReject': 'Reject',
      'wantsToBeFriends': 'Wants to be your friend',
      'presenceOnline': 'Online',
      'presenceOffline': 'Offline',
      'playingNow': 'Playing now',
      'addFriendHint': 'Search by Player ID',
      'playerIdLabel': 'Player ID',
      'searchPlayer': 'Search',
      'requestSent': 'Request Sent',
      'thatsYou': "That's you",
      'enterPlayerId': 'Enter a Player ID.',
      'playerProfile': 'Profile',
      'winRate': 'Win rate',
      'removeFriend': 'Remove Friend',
      'removeFriendQ': 'Remove {name} from your friends?',
      'removeFriendBody': 'You can send them a friend request again later.',
      'removeFriendConfirm': 'Remove',
      'profileLoadFailed': 'Could not load this profile.',
      'back': 'Back',
      'friendAdded': '{name} is now your friend.',
      'friendRemoved': '{name} is no longer your friend.',
      'friendRequestArrived': '{name} sent you a friend request.',
      'friendRequestAtTable':
          '{name} sent you a friend request. Tap their seat to answer.',
      'friendAcceptedYours': '{name} accepted your friend request.',
      'friendMark': 'Friend',
      'friendRefusePlayerNotFound': 'Player not found.',
      'friendRefuseInvalidId': 'That is not a valid Player ID.',
      'friendRefuseSelf': 'You cannot add yourself.',
      'friendRefuseAlreadyFriends': 'You are already friends.',
      'friendRefuseAlreadySent': 'Friend request already sent.',
      'friendRefuseAlreadyReceived':
          'This player already sent you a request — accept it.',
      'friendRefuseRequestGone': 'This friend request is no longer there.',
      'friendRefuseNotPending':
          'This friend request has already been answered.',
      'friendRefuseNotFriends': 'You are not friends with this player.',
      'friendRefuseRateLimited': 'Too many tries. Wait a moment and try again.',
      'friendActionFailed': 'That did not go through. Try again.',
      'addFriendHowTo':
          'Ask your friend for their Player ID — it is at the top of their Friends page.',
      'reportPlayer': 'Report player',
      'reportWhy': 'Why are you reporting this player?',
      'reportReasonCheating': 'Cheating',
      'reportReasonHarassment': 'Harassment',
      'reportReasonAbusiveLanguage': 'Abusive language',
      'reportReasonSpam': 'Spam',
      'reportReasonInappropriate': 'Inappropriate behaviour',
      'reportReasonSuspicious': 'Suspicious gameplay',
      'reportReasonCollusion': 'Collusion',
      'reportReasonExploit': 'Exploiting a bug',
      'reportReasonOther': 'Other',
      'reportDetails': 'Details',
      'reportDetailsHint': 'What happened? (optional)',
      'reportDetailsRequiredHint': 'Describe what happened (required)',
      'reportSubmit': 'Submit report',
      'reportSubmitting': 'Submitting…',
      'reportSubmitted': 'Report submitted',
      'reportThanks': 'Thank you for helping keep the game fair.',
      'reportReview': 'Our team will review the report.',
      'reportDone': 'Done',
      'reportedTag': 'Reported',
      'reportAlready': 'You have already reported this player.',
      'reportLimited':
          'You have sent too many reports. Please try again later.',
      'reportLimitTitle': 'Report limit reached',
      'reportLimitUsed': '{used} of {max} reports used',
      'reportAgainIn': 'You can report again in {time}',
      'reportedTab': 'Reported',
      'myReportsTitle': 'Players you reported',
      'noReportsYet': 'You have not reported anyone.',
      'reportsLoadFailed': 'Couldn’t load your reports.',
      'reportedPlayerGone': 'Deleted player',
      'reportStatusPending': 'Pending',
      'reportStatusUnderReview': 'Under review',
      'reportStatusActionTaken': 'Action taken',
      'reportStatusDismissed': 'Dismissed',
      'reportedOn': 'Reported {when}',
      'reportNotAtTable': 'This player is no longer at your table.',
      'reportInvalidPlayer': 'This player can’t be reported.',
      'reportDescriptionRequired': 'Please describe what happened.',
      'reportDescriptionTooLong': 'Keep the description shorter.',
      'reportNetworkError':
          'Could not send the report. Check your connection and try again.',
      'reportServerError':
          'Something went wrong. Please try again in a moment.',
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
      'statsAll': 'सभी',
      'handsHeld': 'मिले हुए हाथ',
      'variationsPlayed': 'खेले गए वेरिएशन',
      'statsPlayed': 'खेले',
      'statsWon': 'जीते',
      'statsNoVariations': 'अभी कोई वेरिएशन हाथ नहीं',
      'statsPerformance': 'प्रदर्शन',
      'statsAllGames': 'सभी गेम',
      'statsVariations': 'वेरिएशन गेम',
      'statsScopeLabel': 'आँकड़े',
      'statsHandResults': 'हाथों के नतीजे',
      'statsNoHandResults': 'अभी कोई हाथ का नतीजा नहीं',
      'statsNoVariationGames': 'अभी तक कोई वेरिएशन गेम नहीं खेला',
      'statsHandResultsHint':
          'इन्हें देखने के लिए तीन पत्ती या वेरिएशन गेम चुनें',
      'statsVariationsHint': 'इन्हें देखने के लिए वेरिएशन गेम चुनें',
      'luckyDrawChip': 'लकी ड्रॉ',
      'luckyDrawTitle': 'लकी ड्रॉ',
      'luckySpinReady': 'अभी घुमाएँ',
      'luckySpinNow': 'अभी घुमाएँ',
      'luckySpinning': 'घूम रहा है…',
      'luckyNextSpin': 'अगला स्पिन',
      'luckyFreeSpin': 'मुफ़्त स्पिन',
      'luckyNextFreeSpin': 'अगला मुफ़्त स्पिन',
      'luckyEvery': 'हर {time} में एक मुफ़्त स्पिन।',
      'rewardsChip': 'रिवॉर्ड',
      'rewardsTitle': 'दैनिक रिवॉर्ड',
      'rewardsCollect': 'अभी लें',
      'rewardsCollected': 'आज ले लिया',
      'rewardsCollectedTitle': 'दैनिक रिवॉर्ड मिल गए!',
      'streakDayOne': '1 दिन की स्ट्रीक',
      'streakDays': '{n} दिन की स्ट्रीक',
      'streakStart': 'आज अपनी स्ट्रीक शुरू करें',
      'calendarDayReward': 'दिन {n} का रिवॉर्ड',
      'rewardModeStreak': 'लॉगिन स्ट्रीक',
      'rewardModeCalendar': 'कैलेंडर',
      'rewardStreakHint':
          'सीढ़ी चढ़ने के लिए हर दिन लॉगिन करें। एक दिन छूटा तो स्ट्रीक फिर दिन 1 से शुरू होगी।',
      'rewardStreakHintNoReset':
          'सीढ़ी चढ़ने के लिए हर दिन लॉगिन करें। छूटा हुआ दिन बस छूट जाता है।',
      'rewardCalendarWeekHint':
          'हफ़्ते के हर दिन का एक रिवॉर्ड। छूटा दिन छूट गया; बाकी आपका इंतज़ार करते हैं।',
      'rewardCalendarMonthHint':
          'महीने के हर दिन का एक रिवॉर्ड। छूटा दिन छूट गया; बाकी आपका इंतज़ार करते हैं।',
      'rewardNext': 'अगला रिवॉर्ड',
      'rewardDay': 'दिन {n}',
      'rewardToday': 'आज',
      'rewardTileClaimed': 'मिल गया',
      'rewardTileLocked': 'लॉक',
      'rewardTileMissed': 'छूट गया',
      'rewardNone': 'अभी कोई रिवॉर्ड नहीं चल रहा।',
      'rewardLoadFailed': 'रिवॉर्ड लोड नहीं हो सके।',
      'rewardLobbyOnly': 'रिवॉर्ड लॉबी से लें, टेबल पर नहीं।',
      'rewardNothing': 'कोई रिवॉर्ड नहीं',
      'rewardAlreadyOwned': 'पहले से आपका',
      'rewardEmojiName': '{name} इमोजी',
      'rewardPictureName': '{name} तस्वीर',
      'rewardTablePictureName': '{name} टेबल तस्वीर',
      'rewardBadgeName': '{name} बैज',
      'rewardBadgeDays': '{name} बैज · {n} दिन',
      'rewardProgramWeeklyLogin': 'साप्ताहिक लॉगिन स्ट्रीक',
      'rewardProgramMonthlyLogin': 'मासिक लॉगिन स्ट्रीक',
      'rewardProgramWeeklyCalendar': 'साप्ताहिक कैलेंडर रिवॉर्ड',
      'rewardProgramMonthlyCalendar': 'मासिक कैलेंडर रिवॉर्ड',
      'todaysReward': 'आज का रिवॉर्ड: {prize}',
      'rewardsAlso': 'साथ में: {list}',
      'todaysRewardTitle': 'आज का रिवॉर्ड',
      'continueKey': 'जारी रखें',
      'weeklyFinal': 'अंतिम',
      'weekday1': 'सोम',
      'weekday2': 'मंगल',
      'weekday3': 'बुध',
      'weekday4': 'गुरु',
      'weekday5': 'शुक्र',
      'weekday6': 'शनि',
      'weekday7': 'रवि',
      'luckyPrizes': 'पहिये पर इनाम',
      'luckyNoPrize': 'कोई इनाम नहीं',
      'luckyCongrats': 'बधाई हो!',
      'luckyYouWon': 'आपने जीता',
      'luckyNothingTitle': 'अगली बार किस्मत साथ देगी!',
      'luckyNothingBody': 'पहिया खाली खाने पर रुका।',
      'luckyAlreadyOwned':
          'यह तस्वीर पहले से आपकी है, इसलिए कुछ नया अनलॉक नहीं हुआ।',
      'luckyPictureFor': '{time} के लिए आपकी',
      'luckyWearNow': 'अभी लगाएँ',
      'luckyLayNow': 'अभी लगाएँ',
      'luckyProfilePicture': 'प्रोफ़ाइल तस्वीर',
      'luckyTablePicture': 'टेबल की तस्वीर',
      'luckyClosed': 'लकी ड्रॉ अभी बंद है।',
      'luckyLoadFailed': 'लकी ड्रॉ लोड नहीं हो सका।',
      'luckyRetry': 'फिर कोशिश करें',
      'luckyLobbyOnly': 'लकी ड्रॉ लॉबी से घुमाएँ।',
      'luckyNotReady': 'आपका अगला स्पिन अभी तैयार नहीं है।',
      'countMissileOne': '1 मिसाइल',
      'countMissiles': '{n} मिसाइलें',
      'welcomeAdded': 'स्वागत है! आपके खाते में जोड़ा गया: {items}',
      'welcomePlain': 'King Teen Patti में आपका स्वागत है!',
      'countPictureOne': '1 तस्वीर',
      'countPictures': '{n} तस्वीरें',
      'countTablePictureOne': '1 टेबल की तस्वीर',
      'countTablePictures': '{n} टेबल की तस्वीरें',
      'countEmojiOne': '1 इमोजी',
      'countEmojis': '{n} इमोजी',
      'rewardCollected': 'इनाम मिल गया!',
      'rewardPurchased': 'चिप्स आपके वॉलेट में हैं। शुभकामनाएँ।',
      'rewardDiamondsPurchased': 'हीरे आपके वॉलेट में हैं। इनसे मिसाइलें लें।',
      'tapToClose': 'बंद करने के लिए टैप करें',
      'buyChips': 'चिप्स खरीदें',
      'shop': 'दुकान',
      'comingSoon': 'जल्द आ रहा है',
      'updateTitle': 'अपडेट ज़रूरी है',
      'updateBody':
          'खेलना जारी रखने के लिए King Teen Patti का नया वर्ज़न ज़रूरी है।',
      'updateNow': 'अभी अपडेट करें',
      'updateOpenStore': 'प्ले स्टोर खोलें',
      'updateOpenAppStore': 'ऐप स्टोर खोलें',
      'updateFailed': 'अपडेट पूरा नहीं हुआ। कृपया फिर कोशिश करें।',
      // The app version gate (owner, 28 Sep 2026).
      'updateVersionLine': 'आपका वर्ज़न {installed} · ज़रूरी {required}',
      'updateStoreUnavailable':
          'स्टोर नहीं खुल सका। कृपया अपने ऐप स्टोर से King Teen Patti अपडेट करें।',
      'softUpdateTitle': 'नया वर्ज़न उपलब्ध है',
      'softUpdateBody': 'King Teen Patti का एक नया वर्ज़न उपलब्ध है।',
      'softUpdateLater': 'बाद में',
      'maintenanceTitle': 'रखरखाव जारी है',
      'maintenanceBody':
          'King Teen Patti अभी कुछ समय के लिए उपलब्ध नहीं है। कृपया बाद में फिर कोशिश करें।',
      'maintenanceRetry': 'फिर कोशिश करें',
      'purchaseNotLaunched': 'खरीदारी पूरी नहीं हुई।',
      'storeTitle': 'चिप स्टोर',
      'storeBlurb': 'जितना बड़ा पैक, उतना बड़ा बोनस।',
      'storeTabChips': 'चिप्स',
      'storeTabPictures': 'तस्वीरें',
      'storeTabAnimated': 'एनिमेटेड',
      'storePicturesBlurb': 'चिप्स, हथौड़ों या हीरों से तस्वीर अनलॉक करें।',
      'storeAnimatedBlurb': 'हथौड़ों या हीरों से एनिमेटेड तस्वीर अनलॉक करें।',
      'storeTabTables': 'टेबल',
      'storeTablesTitle': 'टेबल की तस्वीरें',
      'storeTablesBlurb': 'अपनी टेबल सजाएँ — एक रूप दिन के लिए, एक रात के लिए।',
      'tableDefault': 'बहती चिप्स',
      'tableDefaultHint': 'डिफ़ॉल्ट बैकग्राउंड',
      'tableInUse': 'लगी हुई',
      'unlockTableTitle': 'यह टेबल अनलॉक करें?',
      'unlockTableBody': '{name} की कीमत {price} है। अभी अनलॉक करके लगाएँ?',
      'unlockTableRentBody':
          '{name} की कीमत {price} है और {time} तक आपकी टेबल सजाती है। अभी अनलॉक करके लगाएँ?',
      'tableChipsLobbyOnly':
          'चिप्स की कीमत वाली टेबल तस्वीर सिर्फ़ लॉबी में खरीदी जा सकती है।',
      'priceChips': '{cost} चिप्स',
      'priceDiamonds': '{cost} हीरे',
      'priceHammers': '{cost} हथौड़े',
      'priceHammerOne': '1 हथौड़ा',
      'priceDiamondOne': '1 हीरा',
      'tablePokerNote':
          'पोकर टेबल पर टेबल पिक्चर नहीं दिखती — यह आपकी अगली तीन पत्ती टेबल पर दिखेगी।',
      // Emojis (owner, 26 Sep 2026).
      'storeTabEmojis': 'इमोजी',
      'storeEmojisTitle': 'इमोजी',
      'storeEmojisBlurb': 'पूरी टेबल को भेजने के लिए एनिमेटेड इमोजी।',
      'storeTabBadges': 'बैज',
      'storeBadgesTitle': 'बैज',
      'storeBadgesBlurb': 'बैज रहते तक आपका जीत टैक्स कम रहता है।',
      'badgeContactSupport': 'सपोर्ट से संपर्क करें',
      'badgeContactTitle': '{badge} पाएँ',
      'badgeContactBody':
          '{badge} हमारी टीम देती है। हमें लिखें, हम इसे पाने में आपकी मदद करेंगे।',
      'badgeMailSubject': 'मुझे {badge} बैज चाहिए',
      'copyAddress': 'पता कॉपी करें',
      'addressCopied': 'पता कॉपी हो गया',
      'emojiShelfEmpty': 'अभी कोई इमोजी नहीं है।',
      'unlockEmojiTitle': 'यह इमोजी अनलॉक करें?',
      'unlockEmojiBody': '{name} की कीमत {price} है। अभी अनलॉक करें?',
      'unlockEmojiRentBody':
          '{name} की कीमत {price} है और यह {time} तक आपका है। अभी अनलॉक करें?',
      'emojiChipsLobbyOnly':
          'चिप्स की कीमत वाला इमोजी सिर्फ़ लॉबी में खरीदा जा सकता है।',
      'emojiOwnedNote': 'यह इमोजी आपका है — इसे टेबल पर इमोजी बटन से भेजें।',
      'tableEmojis': 'इमोजी',
      'emojiSendHint': 'टेबल को भेजने के लिए किसी इमोजी पर टैप करें।',
      'emojiUnlockMore': 'अनलॉक करने के लिए किसी पर टैप करें',
      'emojiNoneOwned':
          'आपके पास अभी कोई इमोजी नहीं है — नीचे से एक अनलॉक करें।',
      'emojiSentBy': '{name} ने {emoji} भेजा',
      'emojiLockedRefusal': 'पहले स्टोर में यह इमोजी अनलॉक करें।',
      'emojiUnknownRefusal': 'यह इमोजी मौजूद नहीं है।',
      'emojiRetiredRefusal': 'यह इमोजी अब उपलब्ध नहीं है।',
      'emojiUnaffordableRefusal':
          'यह इमोजी अनलॉक करने के लिए आपके पास पर्याप्त नहीं है।',
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
      'forceSideshowTooLate':
          'देर हो गई — अब वह साइडशो नहीं हो सकता। कोई हथौड़ा खर्च नहीं हुआ।',
      'settings': 'सेटिंग्स',
      'language': 'भाषा',
      'settingsSubtitle': 'खेल का अनुभव अपने हिसाब से सजाएँ',
      'settingsProfile': 'प्रोफ़ाइल',
      'settingsGameExperience': 'खेल का अनुभव',
      'settingsAccount': 'खाता',
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
      'deleteAccount': 'मेरा खाता हटाएं',
      'deleteAccountTitle': 'खाता हटाना है?',
      'deleteAccountBody':
          'इससे आपका नाम, तस्वीर, आंकड़े और आपके सारे चिप्स मिट जाएंगे, वे भी जो आपने खरीदे थे। यह वापस नहीं हो सकता, और कुछ भी नए खाते में नहीं आएगा।',
      'deleteAccountSeated': 'खाता हटाने से पहले टेबल छोड़ें।',
      'deleteAccountConfirm': 'हमेशा के लिए हटाएं',
      'useProviderPicture': 'मेरी Google तस्वीर लगाएँ',
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
      'teenPatti': 'तीन पत्ती',
      'teenPattiTableNote': 'सीन, ब्लाइंड और वेरिएशन टेबल',
      'viewGames': 'खेल देखें',
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
      'taxPill': '{rate} टैक्स',
      'taxPillNoRate': 'टैक्स',
      'winningTaxTitle': 'जीत टैक्स',
      'winningTaxLabel': 'जीत टैक्स',
      'yourLevelLabel': 'आपका लेवल',
      'xpLabel': 'XP',
      'yourRateLabel': 'आपकी दर',
      'nextLevelLabel': 'अगला लेवल',
      'levelName': 'लेवल {n} · {title}',
      'levelLine': 'लेवल {n} · {title} · {xp} XP',
      'nextLevelValue': '{xp} XP · {rate}',
      'topLevelNote': 'यह सबसे ऊँचा लेवल है।',
      'winningTaxOnlyWinner':
          'जीत टैक्स सिर्फ़ हर हाथ का विजेता देता है, अपनी जीत पर — पॉट में से अपने लगाए चिप्स घटाकर।',
      'winningTaxFalls': 'आपका लेवल जितना ऊँचा, टैक्स उतना कम।',
      'ruleWinningTax':
          'हर हाथ का विजेता अपनी जीत पर जीत टैक्स देता है — पॉट में से अपने लगाए चिप्स घटाकर — लेवल 1 पर {top}, हर अगले लेवल पर कम।',
      'winnerTaxLine': 'जीत टैक्स −{tax}',
      'levelUp': 'लेवल अप! {level} — अब आपका जीत टैक्स {rate} है।',
      'xpToday': 'आज {xp} / {cap} XP',
      'xpResetsIn': '{time} में रीसेट',
      'todayLabel': 'आज',
      'levelUpOnly': 'लेवल अप! {level}',
      'allLevelsTitle': 'सभी लेवल',
      'levelTabMine': 'मेरा लेवल',
      'yourLevelTitle': 'आपका लेवल',
      'badgesTitle': 'बैज',
      'yourBadgesTitle': 'आपके बैज',
      'avatarBadgeSemantics': '{badge} बैज',
      'taxColumn': 'टैक्स',
      'levelYou': 'आप',
      'levelTaxLabel': 'लेवल टैक्स',
      'winningTaxLowest':
          'आप अपने लेवल और बैज की दरों में से सबसे कम दर देते हैं।',
      'rateSetByLevel': 'आपके लेवल से तय',
      'rateSetByBadge': 'आपके {badge} बैज से तय',
      'xpDailyTitle': 'रोज़ का XP',
      'xpPlayMinutes': '{n} मिनट सक्रिय खेलें',
      'xpWinBy': '{hand} से जीतें',
      'xpMissionDone': 'मिशन पूरा: {mission}',
      'xpGained': '+{xp} XP',
      'xpMissionFallback': 'रोज़ का XP मिशन',
      'xpBarTaxNow': 'अब जीत टैक्स {rate}',
      'xpListResets': 'यह सूची हर {time} में फिर से शुरू होती है।',
      'xpEarned': 'मिल गया',
      'xpDailyCap': 'हर {time} में ज़्यादा से ज़्यादा {cap} XP।',
      'xpNeverExpires': 'XP और लेवल कभी खत्म नहीं होते।',
      'levelNumber': 'लेवल {n}',
      'xpOf': '{xp} / {max} XP',
      'xpToNext': '{title} के लिए {xp} XP और',
      'levelNextLine': 'अगला: {level} · {xp} XP · {rate} टैक्स',
      'taxNoteWinner':
          'सिर्फ़ हाथ जीतने वाला अपनी शुद्ध जीत पर जीत टैक्स देता है।',
      'taxNoteNet': 'शुद्ध जीत = पॉट − उसमें आपके अपने चिप्स।',
      'taxNoteBadge': 'सक्रिय बैज आपका टैक्स और घटा सकता है।',
      'badgeActive': 'सक्रिय',
      'levelMax': 'सबसे ऊँचा लेवल',
      'levelShort': 'लेवल {n}',
      'levelBarSemantics': 'लेवल {n}, {max} में से {xp} XP',
      'levelBarTopSemantics': 'लेवल {n}, {xp} XP, सबसे ऊँचा लेवल',
      'levelHowTax': 'जीत टैक्स कैसे लगता है',
      'badgeSetsRate': 'आपकी दर तय करता है',
      'badgeExpiresIn': '{time} में खत्म',
      'badgeExpired': 'खत्म हो गया',
      'badgeYours': 'आपका',
      'badgeRoyalHint': 'रॉयल बैज आपका जीत टैक्स {rate} तक घटा देते हैं।',
      'badgeSeeStore': 'बैज देखें',
      'badgesBesideLevel':
          'बैज आपके लेवल के साथ रहते हैं; XP से बैज नहीं मिलता।',
      'xpEarnedToday': 'आज मिला',
      'xpDailyComplete': 'रोज़ का XP पूरा',
      'xpDailyCompleteNote':
          'आपने आज का सारा XP पा लिया। रीसेट के बाद फिर मिलेगा।',
      'xpResetsInCap': '{time} में रीसेट',
      'xpWindowIdle': 'आपका दिन अगले हाथ से शुरू होगा।',
      'xpPlayTimeTitle': 'खेलने का समय',
      'xpPlayTimeNote':
          'सक्रिय खेल जैसे-जैसे हर पड़ाव पर पहुँचता है, उसका XP दिन में एक बार मिलता है, और सब जुड़ते जाते हैं।',
      'xpMinutes': '{n} मिनट',
      'xpWinHandsTitle': 'जीत वाले हाथ',
      'xpWinHandsNote':
          'इनमें से हर एक से हाथ जीतें और उसका XP पाएँ, दिन में एक बार।',
      'levelNextTag': 'अगला',
      'levelColumn': 'लेवल',
      'unitDayShort': 'दि',
      'badgeAvailable': 'उपलब्ध',
      'xpOtherTitle': 'XP पाने के और तरीके',
      'xpOneTimeTitle': 'एक बार के मिशन',
      'xpOneTimeNote':
          'हर मिशन अपना XP एक ही बार देता है। ये कभी रीसेट नहीं होते।',
      'xpOneTimeDone': '{n} / {of} पूरे',
      'xpOneTimeTab': 'एक बार का XP',
      'xpOneTimeNone': 'अभी कोई एक बार का मिशन नहीं है।',
      'xpMissionCompleted': 'पूरा हुआ',
      'xpMissionPlayHand1': '1 हाथ खेलें',
      'xpMissionPlayHands': '{n} हाथ खेलें',
      'xpMissionWinHand1': '1 हाथ जीतें',
      'xpMissionWinHands': '{n} हाथ जीतें',
      'xpMissionPlayGameHand1': '{game} का 1 हाथ खेलें',
      'xpMissionPlayGameHands': '{game} के {n} हाथ खेलें',
      'xpMissionWinGameHand1': '{game} का 1 हाथ जीतें',
      'xpMissionWinGameHands': '{game} के {n} हाथ जीतें',
      'xpMissionGames': '{n} अलग-अलग गेम खेलें',
      'xpMissionGamesIn': '{game} के {n} अलग-अलग गेम खेलें',
      'xpMissionVariations': '{n} अलग-अलग वेरिएशन खेलें',
      'badgeUntil': '{date} तक',
      'badgeEveryone': 'सभी के लिए',
      'badgeLasts': '{time} तक',
      'levelsUnavailable': 'लेवल लोड नहीं हो सके।',
      'ruleWinningTaxBadge': 'बैज इसे और कम कर सकता है।',
      'winningTaxFrom': '{amount} से कम की जीत पर कोई टैक्स नहीं।',
      'taxOnWinningsFrom': '{amount} या उससे ज़्यादा की जीत पर',
      'badgeLifetime': 'आजीवन',
      'badgeFree': 'मुफ़्त',
      'badgeTaxLine': '{rate} जीत टैक्स',
      'badgeBought': '{badge} अब {date} तक आपका है।',
      'variationRulesIntro':
          'पहली चाल वाले खिलाड़ी के पास यह चुनने के लिए 10 सेकंड होते हैं कि हाथ किस नियम से तय होगा; न चुनने पर मुफ़लिस खेला जाता है। जोकर पत्ता वही पत्ता माना जाता है जिससे आपका हाथ सबसे अच्छा बने। दूसरों के चिप्स छिपे रहते हैं और पॉट की कोई सीमा नहीं है।',
      'variationChooseTitle': 'वेरिएशन चुनें',
      'pickTitle': 'अपने तीन कार्ड चुनें',
      'pickHint': 'खेलने के लिए अपने पाँच में से तीन कार्ड चुनें',
      'pickConfirm': 'ये तीन खेलें',
      'pickThreeCards': 'अपने ही तीन कार्ड चुनें',
      'pickWasBest': 'आपने सबसे अच्छा संयोजन खेला',
      'pickNotBest': 'आपने यह खेला। सबसे अच्छा यह था:',
      'pickTimedOut': 'समय समाप्त — आपके पहले तीन कार्ड खेले गए',
      'pickYouPlayed': 'आपने खेला',
      'pickTheBest': 'सबसे अच्छा',
      'pickChoosing': '{name} कार्ड चुन रहे हैं…',
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
      'sideshowPendingRefusal': 'पहले साइडशो के जवाब का इंतज़ार करें',
      'pickPendingRefusal':
          'एक पल रुकें: एक खिलाड़ी अभी अपने तीन कार्ड चुन रहा है',
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
      'autoPacked': 'आपकी बारी छूट गई — अपने-आप पैक हुआ',
      'missedYourTurn': 'आपकी बारी छूट गई',
      'lastWarning': 'आखिरी चेतावनी',
      'missOneMore': 'एक और बारी छूटी तो आप टेबल से बाहर हो जाएंगे',
      'missedTurnsCount': 'छूटी बारियाँ: {max} में से {n}',
      'resumingTable': 'आपकी टेबल पर वापस जा रहे हैं…',
      'pleaseWait': 'कृपया प्रतीक्षा करें...',
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
      'block': 'ब्लॉक करें',
      'unblock': 'अनब्लॉक करें',
      'blockPlayersTitle': 'खिलाड़ियों को ब्लॉक करें',
      'blockNobody': 'अभी टेबल पर कोई और नहीं है।',
      'saySomething': 'कुछ कहें…',
      'tableMenu': 'टेबल मेनू',
      'quickMessagesTitle': 'झटपट संदेश',
      'quickMessagesTip': 'झटपट संदेश भेजें',
      'quickReorderHint': 'क्रम बदलने के लिए दबाकर खींचें',
      'quickAddMessage': 'संदेश जोड़ें',
      'quickCustomHint': 'अपना संदेश लिखें',
      'quickCustomDuplicate': 'यह संदेश पहले से आपकी सूची में है।',
      'quickCustomFull': 'आप अपने 10 संदेश तक सहेज सकते हैं।',
      'quickDeleteMessage': 'संदेश हटाएँ',
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
      'priceLabel': 'कीमत',
      'youHaveLabel': 'आपके पास',
      'unlockBody': '{name} की कीमत {cost} चिप्स है। अभी अनलॉक करके लगाएँ?',
      'unlockBodyDiamond':
          '{name} की कीमत {cost} डायमंड है। अभी अनलॉक करके लगाएँ?',
      'pictureUnlocked': 'अनलॉक',
      'pictureOwned': 'आपकी',
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
      'timeMonth': '{n} महीना',
      'timeMonths': '{n} महीने',
      'timeYear': '{n} साल',
      'timeYears': '{n} साल',
      'friendsFor': '{time} से दोस्त',
      'friendsJustNow': 'अभी-अभी दोस्त बने',
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
      'accountDisabledTitle': 'खाता निष्क्रिय है',
      'accountDisabledBody':
          'आपका खाता निष्क्रिय कर दिया गया है। कृपया सपोर्ट से संपर्क करें।',
      'googlePhoto': 'Google फ़ोटो',
      'ownPhoto': 'आपकी फ़ोटो',
      'sessionReplacedTitle': 'दूसरे डिवाइस पर साइन इन हुआ',
      'sessionReplacedBody':
          'किसी ने दूसरे डिवाइस पर आपके खाते में साइन इन किया है, इसलिए आपको यहाँ से साइन आउट कर दिया गया है। इस फ़ोन पर खेलने के लिए फिर से साइन इन करें — तब दूसरा डिवाइस साइन आउट हो जाएगा।',
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
      'useSocialPicture': 'मेरी Google तस्वीर लगाएँ',
      'guestNoSocial': 'अपनी तस्वीर लगाने के लिए Google से साइन इन करें।',

      // --- the poker family
      'poker': 'पोकर',
      'pokerTableNote': 'होल्डम, ओमाहा, 5-कार्ड ड्रॉ और 3-कार्ड पोकर',
      'pokerTexasHoldem': 'टेक्सस होल्डम',
      'pokerOmaha': 'ओमाहा',
      'pokerFiveCardDraw': '5-कार्ड ड्रॉ',
      'pokerThreeCardPoker': '3-कार्ड पोकर',
      'pokerTexasHoldemNote': 'हर एक को दो पत्ते, बोर्ड पर पाँच',
      'pokerOmahaNote': 'हर एक को चार पत्ते, उनमें से ठीक दो खेलें',
      'pokerFiveCardDrawNote':
          'हर एक को पाँच पत्ते, जो नहीं चाहिए उन्हें बदलें',
      'pokerThreeCardPokerNote': 'हर एक को तीन पत्ते, डीलर के खिलाफ़',
      'blindsLabel': 'ब्लाइंड्स',
      'anteLabel': 'एंटी',
      'blindsTitle': 'ब्लाइंड्स',
      'anteTitle': 'एंटी',
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
      'rulePokerDrawWin':
          'बेट करें, एक बार {n} तक पत्ते बदलें, फिर दोबारा बेट करें',
      'rulePokerThreeCardWin':
          'एंटी के बराबर प्ले करें या फ़ोल्ड; आपके तीन पत्ते डीलर से मिलाए जाते हैं',
      'rulePokerDealerQualifies':
          'डीलर को खेलने के लिए क्वीन-हाई चाहिए; न हो तो आपका प्ले बेट वापस और '
          'एंटी जीतती है',
      'rulePokerBestHandWins':
          'शोडाउन में सबसे अच्छा हाथ पॉट लेता है; अकेला बचा खिलाड़ी बिना शोडाउन के',
      'rulePokerStreets':
          'दांव प्री-फ्लॉप, फिर फ्लॉप, टर्न और रिवर पर लगते हैं',
      'rulePokerBetTo':
          'बेट या रेज़ इस स्ट्रीट के लिए आपकी कुल रकम बताता है, ऊपर से जोड़ी गई रकम नहीं',
      'rulePokerDrawStreets': 'ड्रॉ से पहले एक बार और उसके बाद एक बार दांव',
      'rulePokerPlayBet':
          'प्ले करने पर एंटी जितना दूसरा दांव लगता है; फ़ोल्ड करने पर एंटी घर के पास रह जाती है',
      'pokerTableRankingTitle': 'यहाँ क्या किससे बड़ा है',
      'pokerTableRankingIntro':
          'आपका हाथ आपके सबसे अच्छे पाँच पत्ते होते हैं, इस क्रम में।',
      'pokerThreeCardRankingIntro':
          'हर एक को तीन पत्ते, अपनी अलग सीढ़ी पर — न पाँच पत्तों का क्रम, न तीन पत्ती का।',
      'rulePokerThreeCardRuns': 'A-K-Q सबसे बड़ी रन है और A-2-3 सबसे छोटी',
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
      // Friends (owner, 26 Sep 2026)
      'friends': 'दोस्त',
      'friendsOnlineCount': '{n} ऑनलाइन',
      'friendRequestWaiting': '1 नई फ़्रेंड रिक्वेस्ट',
      'friendRequestsWaiting': '{n} नई फ़्रेंड रिक्वेस्ट',
      'yourPlayerId': 'आपकी खिलाड़ी आईडी',
      'copyId': 'कॉपी करें',
      'idCopied': 'कॉपी हो गई',
      'addFriend': 'दोस्त जोड़ें',
      'friendRequests': 'फ़्रेंड रिक्वेस्ट',
      'noFriendRequests': 'कोई फ़्रेंड रिक्वेस्ट नहीं',
      'noFriendsTitle': 'अभी कोई दोस्त नहीं',
      'noFriendsBody': 'दोस्तों को उनकी खिलाड़ी आईडी से जोड़ें।',
      'friendsLoadFailed': 'दोस्तों की सूची लोड नहीं हो सकी।',
      'friendsRetry': 'फिर कोशिश करें',
      'friendAccept': 'स्वीकारें',
      'friendReject': 'अस्वीकारें',
      'wantsToBeFriends': 'आपका दोस्त बनना चाहते हैं',
      'presenceOnline': 'ऑनलाइन',
      'presenceOffline': 'ऑफ़लाइन',
      'playingNow': 'अभी खेल रहे हैं',
      'addFriendHint': 'खिलाड़ी आईडी से खोजें',
      'playerIdLabel': 'खिलाड़ी आईडी',
      'searchPlayer': 'खोजें',
      'requestSent': 'रिक्वेस्ट भेजी गई',
      'thatsYou': 'यह आप हैं',
      'enterPlayerId': 'खिलाड़ी आईडी डालें।',
      'playerProfile': 'प्रोफ़ाइल',
      'winRate': 'जीत दर',
      'removeFriend': 'दोस्त हटाएँ',
      'removeFriendQ': '{name} को अपने दोस्तों से हटाएँ?',
      'removeFriendBody':
          'आप बाद में उन्हें फिर से फ़्रेंड रिक्वेस्ट भेज सकते हैं।',
      'removeFriendConfirm': 'हटाएँ',
      'profileLoadFailed': 'यह प्रोफ़ाइल लोड नहीं हो सकी।',
      'back': 'वापस',
      'friendAdded': '{name} अब आपके दोस्त हैं।',
      'friendRemoved': '{name} अब आपके दोस्त नहीं हैं।',
      'friendRequestArrived': '{name} ने आपको फ़्रेंड रिक्वेस्ट भेजी है।',
      'friendRequestAtTable':
          '{name} ने आपको फ़्रेंड रिक्वेस्ट भेजी है। जवाब देने के लिए उनकी सीट पर टैप करें।',
      'friendAcceptedYours': '{name} ने आपकी फ़्रेंड रिक्वेस्ट स्वीकार कर ली।',
      'friendMark': 'दोस्त',
      'friendRefusePlayerNotFound': 'खिलाड़ी नहीं मिला।',
      'friendRefuseInvalidId': 'यह सही खिलाड़ी आईडी नहीं है।',
      'friendRefuseSelf': 'आप खुद को नहीं जोड़ सकते।',
      'friendRefuseAlreadyFriends': 'आप पहले से दोस्त हैं।',
      'friendRefuseAlreadySent': 'फ़्रेंड रिक्वेस्ट पहले ही भेजी जा चुकी है।',
      'friendRefuseAlreadyReceived':
          'इस खिलाड़ी ने आपको पहले ही रिक्वेस्ट भेजी है — उसे स्वीकारें।',
      'friendRefuseRequestGone': 'यह फ़्रेंड रिक्वेस्ट अब नहीं है।',
      'friendRefuseNotPending':
          'इस फ़्रेंड रिक्वेस्ट का जवाब पहले ही दिया जा चुका है।',
      'friendRefuseNotFriends': 'आप इस खिलाड़ी के दोस्त नहीं हैं।',
      'friendRefuseRateLimited':
          'बहुत ज़्यादा कोशिशें। थोड़ा रुककर फिर कोशिश करें।',
      'friendActionFailed': 'यह नहीं हो सका। फिर कोशिश करें।',
      'addFriendHowTo':
          'अपने दोस्त से उनकी खिलाड़ी आईडी पूछें — यह उनके दोस्त पेज में सबसे ऊपर होती है।',
      'reportPlayer': 'खिलाड़ी की रिपोर्ट करें',
      'reportWhy': 'आप इस खिलाड़ी की रिपोर्ट क्यों कर रहे हैं?',
      'reportReasonCheating': 'धोखाधड़ी',
      'reportReasonHarassment': 'परेशान करना',
      'reportReasonAbusiveLanguage': 'अभद्र भाषा',
      'reportReasonSpam': 'स्पैम',
      'reportReasonInappropriate': 'अनुचित व्यवहार',
      'reportReasonSuspicious': 'संदिग्ध खेल',
      'reportReasonCollusion': 'मिलीभगत',
      'reportReasonExploit': 'बग का फ़ायदा उठाना',
      'reportReasonOther': 'अन्य',
      'reportDetails': 'विवरण',
      'reportDetailsHint': 'क्या हुआ? (वैकल्पिक)',
      'reportDetailsRequiredHint': 'बताएँ कि क्या हुआ (ज़रूरी)',
      'reportSubmit': 'रिपोर्ट भेजें',
      'reportSubmitting': 'भेजा जा रहा है…',
      'reportSubmitted': 'रिपोर्ट भेज दी गई',
      'reportThanks': 'खेल को निष्पक्ष रखने में मदद के लिए धन्यवाद।',
      'reportReview': 'हमारी टीम इस रिपोर्ट की जाँच करेगी।',
      'reportDone': 'ठीक है',
      'reportedTag': 'रिपोर्ट की गई',
      'reportAlready': 'आप इस खिलाड़ी की रिपोर्ट पहले ही कर चुके हैं।',
      'reportLimited':
          'आपने बहुत सारी रिपोर्ट भेजी हैं। कृपया बाद में फिर कोशिश करें।',
      'reportLimitTitle': 'रिपोर्ट की सीमा पूरी',
      'reportLimitUsed': '{max} में से {used} रिपोर्ट इस्तेमाल',
      'reportAgainIn': '{time} बाद फिर रिपोर्ट कर सकेंगे',
      'reportedTab': 'रिपोर्ट किए',
      'myReportsTitle': 'आपने जिनकी रिपोर्ट की',
      'noReportsYet': 'आपने अभी तक किसी की रिपोर्ट नहीं की है।',
      'reportsLoadFailed': 'आपकी रिपोर्ट लोड नहीं हो सकीं।',
      'reportedPlayerGone': 'हटाया गया खिलाड़ी',
      'reportStatusPending': 'लंबित',
      'reportStatusUnderReview': 'समीक्षा में',
      'reportStatusActionTaken': 'कार्रवाई की गई',
      'reportStatusDismissed': 'खारिज',
      'reportedOn': '{when} को रिपोर्ट किया',
      'reportNotAtTable': 'यह खिलाड़ी अब आपकी टेबल पर नहीं है।',
      'reportInvalidPlayer': 'इस खिलाड़ी की रिपोर्ट नहीं की जा सकती।',
      'reportDescriptionRequired': 'कृपया बताएँ कि क्या हुआ।',
      'reportDescriptionTooLong': 'विवरण थोड़ा छोटा रखें।',
      'reportNetworkError':
          'रिपोर्ट नहीं भेजी जा सकी। अपना कनेक्शन जाँचें और फिर कोशिश करें।',
      'reportServerError': 'कुछ गड़बड़ हो गई। थोड़ी देर में फिर कोशिश करें।',
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
      'statsAll': 'সব',
      'handsHeld': 'পাওয়া হাত',
      'variationsPlayed': 'খেলা ভেরিয়েশন',
      'statsPlayed': 'খেলা',
      'statsWon': 'জেতা',
      'statsNoVariations': 'এখনও কোনো ভেরিয়েশন হাত নেই',
      'statsPerformance': 'পারফরম্যান্স',
      'statsAllGames': 'সব গেম',
      'statsVariations': 'ভেরিয়েশন গেম',
      'statsScopeLabel': 'পরিসংখ্যান',
      'statsHandResults': 'হাতের ফলাফল',
      'statsNoHandResults': 'এখনও কোনো হাতের ফলাফল নেই',
      'statsNoVariationGames': 'এখনও কোনো ভেরিয়েশন গেম খেলা হয়নি',
      'statsHandResultsHint': 'দেখতে তিন পাত্তি বা ভেরিয়েশন গেম বেছে নিন',
      'statsVariationsHint': 'দেখতে ভেরিয়েশন গেম বেছে নিন',
      'luckyDrawChip': 'লাকি ড্র',
      'luckyDrawTitle': 'লাকি ড্র',
      'luckySpinReady': 'এখনই ঘোরান',
      'luckySpinNow': 'এখনই ঘোরান',
      'luckySpinning': 'ঘুরছে…',
      'luckyNextSpin': 'পরের স্পিন',
      'luckyFreeSpin': 'ফ্রি স্পিন',
      'luckyNextFreeSpin': 'পরের ফ্রি স্পিন',
      'luckyEvery': '{time} পরপর একটি ফ্রি স্পিন।',
      'rewardsChip': 'রিওয়ার্ড',
      'rewardsTitle': 'দৈনিক রিওয়ার্ড',
      'rewardsCollect': 'এখনই নিন',
      'rewardsCollected': 'আজ নেওয়া হয়েছে',
      'rewardsCollectedTitle': 'দৈনিক রিওয়ার্ড পাওয়া গেছে!',
      'streakDayOne': '1 দিনের স্ট্রিক',
      'streakDays': '{n} দিনের স্ট্রিক',
      'streakStart': 'আজই আপনার স্ট্রিক শুরু করুন',
      'calendarDayReward': 'দিন {n}-এর রিওয়ার্ড',
      'rewardModeStreak': 'লগইন স্ট্রিক',
      'rewardModeCalendar': 'ক্যালেন্ডার',
      'rewardStreakHint':
          'ধাপে ধাপে উঠতে প্রতিদিন লগইন করুন। একদিন বাদ গেলে স্ট্রিক আবার দিন 1 থেকে শুরু হবে।',
      'rewardStreakHintNoReset':
          'ধাপে ধাপে উঠতে প্রতিদিন লগইন করুন। বাদ যাওয়া দিন শুধু বাদই যায়।',
      'rewardCalendarWeekHint':
          'সপ্তাহের প্রতিটি দিনের একটি রিওয়ার্ড। বাদ যাওয়া দিন বাদ; বাকিগুলো আপনার অপেক্ষায়।',
      'rewardCalendarMonthHint':
          'মাসের প্রতিটি দিনের একটি রিওয়ার্ড। বাদ যাওয়া দিন বাদ; বাকিগুলো আপনার অপেক্ষায়।',
      'rewardNext': 'পরের রিওয়ার্ড',
      'rewardDay': 'দিন {n}',
      'rewardToday': 'আজ',
      'rewardTileClaimed': 'পাওয়া গেছে',
      'rewardTileLocked': 'লক',
      'rewardTileMissed': 'বাদ গেছে',
      'rewardNone': 'এখন কোনো রিওয়ার্ড চলছে না।',
      'rewardLoadFailed': 'রিওয়ার্ড লোড করা যায়নি।',
      'rewardLobbyOnly': 'রিওয়ার্ড লবি থেকে নিন, টেবিলে নয়।',
      'rewardNothing': 'কোনো রিওয়ার্ড নেই',
      'rewardAlreadyOwned': 'আগে থেকেই আপনার',
      'rewardEmojiName': '{name} ইমোজি',
      'rewardPictureName': '{name} ছবি',
      'rewardTablePictureName': '{name} টেবিল ছবি',
      'rewardBadgeName': '{name} ব্যাজ',
      'rewardBadgeDays': '{name} ব্যাজ · {n} দিন',
      'rewardProgramWeeklyLogin': 'সাপ্তাহিক লগইন স্ট্রিক',
      'rewardProgramMonthlyLogin': 'মাসিক লগইন স্ট্রিক',
      'rewardProgramWeeklyCalendar': 'সাপ্তাহিক ক্যালেন্ডার রিওয়ার্ড',
      'rewardProgramMonthlyCalendar': 'মাসিক ক্যালেন্ডার রিওয়ার্ড',
      'todaysReward': 'আজকের রিওয়ার্ড: {prize}',
      'rewardsAlso': 'সাথে: {list}',
      'todaysRewardTitle': 'আজকের রিওয়ার্ড',
      'continueKey': 'চালিয়ে যান',
      'weeklyFinal': 'শেষ',
      'weekday1': 'সোম',
      'weekday2': 'মঙ্গল',
      'weekday3': 'বুধ',
      'weekday4': 'বৃহঃ',
      'weekday5': 'শুক্র',
      'weekday6': 'শনি',
      'weekday7': 'রবি',
      'luckyPrizes': 'চাকার পুরস্কার',
      'luckyNoPrize': 'কোনো পুরস্কার নেই',
      'luckyCongrats': 'অভিনন্দন!',
      'luckyYouWon': 'আপনি জিতেছেন',
      'luckyNothingTitle': 'পরের বার ভাগ্য সহায় হবে!',
      'luckyNothingBody': 'চাকা খালি ঘরে থেমেছে।',
      'luckyAlreadyOwned': 'এটি আগে থেকেই আপনার, তাই নতুন কিছু আনলক হয়নি।',
      'luckyPictureFor': '{time} ধরে আপনার',
      'luckyWearNow': 'এখনই ব্যবহার করুন',
      'luckyLayNow': 'এখনই ব্যবহার করুন',
      'luckyProfilePicture': 'প্রোফাইল ছবি',
      'luckyTablePicture': 'টেবিলের ছবি',
      'luckyClosed': 'লাকি ড্র এখন বন্ধ।',
      'luckyLoadFailed': 'লাকি ড্র লোড করা যায়নি।',
      'luckyRetry': 'আবার চেষ্টা করুন',
      'luckyLobbyOnly': 'লাকি ড্র লবি থেকে ঘোরান।',
      'luckyNotReady': 'আপনার পরের স্পিন এখনও তৈরি নয়।',
      'countMissileOne': '1টি মিসাইল',
      'countMissiles': '{n}টি মিসাইল',
      'welcomeAdded': 'স্বাগতম! আপনার অ্যাকাউন্টে যোগ হয়েছে: {items}',
      'welcomePlain': 'King Teen Patti-তে আপনাকে স্বাগতম!',
      'countPictureOne': '1টি ছবি',
      'countPictures': '{n}টি ছবি',
      'countTablePictureOne': '1টি টেবিলের ছবি',
      'countTablePictures': '{n}টি টেবিলের ছবি',
      'countEmojiOne': '1টি ইমোজি',
      'countEmojis': '{n}টি ইমোজি',
      'rewardCollected': 'পুরস্কার সংগ্রহ হয়েছে!',
      'rewardPurchased': 'চিপ আপনার ওয়ালেটে আছে। শুভকামনা।',
      'rewardDiamondsPurchased':
          'হীরে আপনার ওয়ালেটে আছে। এগুলো দিয়ে মিসাইল নিন।',
      'tapToClose': 'বন্ধ করতে ট্যাপ করুন',
      'buyChips': 'চিপ কিনুন',
      'shop': 'দোকান',
      'comingSoon': 'শীঘ্রই আসছে',
      'updateTitle': 'আপডেট প্রয়োজন',
      'updateBody':
          'খেলা চালিয়ে যেতে King Teen Patti-র নতুন সংস্করণ প্রয়োজন।',
      'updateNow': 'এখনই আপডেট করুন',
      'updateOpenStore': 'প্লে স্টোর খুলুন',
      'updateOpenAppStore': 'অ্যাপ স্টোর খুলুন',
      'updateFailed': 'আপডেট শেষ হয়নি। আবার চেষ্টা করুন।',
      // The app version gate (owner, 28 Sep 2026).
      'updateVersionLine': 'আপনার সংস্করণ {installed} · প্রয়োজন {required}',
      'updateStoreUnavailable':
          'স্টোর খোলা গেল না। অনুগ্রহ করে আপনার অ্যাপ স্টোর থেকে King Teen Patti আপডেট করুন।',
      'softUpdateTitle': 'নতুন সংস্করণ উপলব্ধ',
      'softUpdateBody': 'King Teen Patti-র একটি নতুন সংস্করণ উপলব্ধ।',
      'softUpdateLater': 'পরে',
      'maintenanceTitle': 'রক্ষণাবেক্ষণ চলছে',
      'maintenanceBody':
          'King Teen Patti সাময়িকভাবে অনুপলব্ধ। অনুগ্রহ করে পরে আবার চেষ্টা করুন।',
      'maintenanceRetry': 'আবার চেষ্টা করুন',
      'purchaseNotLaunched': 'কেনাকাটা সম্পন্ন হয়নি।',
      'storeTitle': 'চিপ স্টোর',
      'storeBlurb': 'প্যাক যত বড়, বোনাসও তত বড়।',
      'storeTabChips': 'চিপস',
      'storeTabPictures': 'ছবি',
      'storeTabAnimated': 'অ্যানিমেটেড',
      'storePicturesBlurb': 'চিপস, হাতুড়ি বা হীরে দিয়ে ছবি আনলক করুন।',
      'storeAnimatedBlurb':
          'হাতুড়ি বা হীরে দিয়ে একটি অ্যানিমেটেড ছবি আনলক করুন।',
      'storeTabTables': 'টেবিল',
      'storeTablesTitle': 'টেবিলের ছবি',
      'storeTablesBlurb': 'আপনার টেবিল সাজান — একটি রূপ দিনের, একটি রাতের।',
      'tableDefault': 'ভাসমান চিপস',
      'tableDefaultHint': 'ডিফল্ট ব্যাকগ্রাউন্ড',
      'tableInUse': 'ব্যবহারে',
      'unlockTableTitle': 'এই টেবিলটি আনলক করবেন?',
      'unlockTableBody': '{name} এর দাম {price}। এখনই আনলক করে ব্যবহার করবেন?',
      'unlockTableRentBody':
          '{name} এর দাম {price} এবং {time} আপনার টেবিল সাজায়। এখনই আনলক করে ব্যবহার করবেন?',
      'tableChipsLobbyOnly': 'চিপসের দামের টেবিল ছবি শুধু লবিতে কেনা যায়।',
      'priceChips': '{cost} চিপস',
      'priceDiamonds': '{cost}টি হীরে',
      'priceHammers': '{cost}টি হাতুড়ি',
      'priceHammerOne': '1টি হাতুড়ি',
      'priceDiamondOne': '1টি হীরে',
      'tablePokerNote':
          'পোকার টেবিলে টেবিল ছবি দেখা যায় না — এটি আপনার পরের তিন পাত্তি টেবিলে দেখা যাবে।',
      // Emojis (owner, 26 Sep 2026).
      'storeTabEmojis': 'ইমোজি',
      'storeEmojisTitle': 'ইমোজি',
      'storeEmojisBlurb': 'পুরো টেবিলে পাঠানোর জন্য অ্যানিমেটেড ইমোজি।',
      'storeTabBadges': 'ব্যাজ',
      'storeBadgesTitle': 'ব্যাজ',
      'storeBadgesBlurb':
          'ব্যাজ যতদিন থাকে, আপনার জয়ের ট্যাক্স ততদিন কম থাকে।',
      'badgeContactSupport': 'সাপোর্টে যোগাযোগ করুন',
      'badgeContactTitle': '{badge} পান',
      'badgeContactBody':
          '{badge} আমাদের টিম দেয়। আমাদের লিখুন, আমরা এটি পেতে আপনাকে সাহায্য করব।',
      'badgeMailSubject': 'আমি {badge} ব্যাজ চাই',
      'copyAddress': 'ঠিকানা কপি করুন',
      'addressCopied': 'ঠিকানা কপি হয়েছে',
      'emojiShelfEmpty': 'এখনও কোনো ইমোজি নেই।',
      'unlockEmojiTitle': 'এই ইমোজিটি আনলক করবেন?',
      'unlockEmojiBody': '{name} এর দাম {price}। এখনই আনলক করবেন?',
      'unlockEmojiRentBody':
          '{name} এর দাম {price} এবং এটি {time} আপনার। এখনই আনলক করবেন?',
      'emojiChipsLobbyOnly': 'চিপসের দামের ইমোজি শুধু লবিতে কেনা যায়।',
      'emojiOwnedNote': 'এই ইমোজিটি আপনার — টেবিলে ইমোজি বোতাম দিয়ে পাঠান।',
      'tableEmojis': 'ইমোজি',
      'emojiSendHint': 'টেবিলে পাঠাতে একটি ইমোজিতে ট্যাপ করুন।',
      'emojiUnlockMore': 'আনলক করতে যেকোনো একটিতে ট্যাপ করুন',
      'emojiNoneOwned': 'আপনার এখনও কোনো ইমোজি নেই — নিচে থেকে একটি আনলক করুন।',
      'emojiSentBy': '{name} {emoji} পাঠিয়েছেন',
      'emojiLockedRefusal': 'আগে স্টোরে এই ইমোজিটি আনলক করুন।',
      'emojiUnknownRefusal': 'এই ইমোজিটি নেই।',
      'emojiRetiredRefusal': 'এই ইমোজিটি আর পাওয়া যায় না।',
      'emojiUnaffordableRefusal': 'এই ইমোজিটি আনলক করার মতো যথেষ্ট আপনার নেই।',
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
      'forceSideshowTooLate':
          'দেরি হয়ে গেছে — সেই সাইডশো আর সম্ভব নয়। কোনো হাতুড়ি খরচ হয়নি।',
      'settings': 'সেটিংস',
      'language': 'ভাষা',
      'settingsSubtitle': 'খেলার অভিজ্ঞতা নিজের মতো সাজান',
      'settingsProfile': 'প্রোফাইল',
      'settingsGameExperience': 'খেলার অভিজ্ঞতা',
      'settingsAccount': 'অ্যাকাউন্ট',
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
      'deleteAccount': 'আমার অ্যাকাউন্ট মুছুন',
      'deleteAccountTitle': 'অ্যাকাউন্ট মুছবেন?',
      'deleteAccountBody':
          'এতে আপনার নাম, ছবি, পরিসংখ্যান এবং আপনার সব চিপ মুছে যাবে, যেগুলি আপনি কিনেছিলেন সেগুলিও। এটি ফেরানো যায় না, এবং কিছুই নতুন অ্যাকাউন্টে ফিরবে না।',
      'deleteAccountSeated': 'অ্যাকাউন্ট মোছার আগে টেবিল ছাড়ুন।',
      'deleteAccountConfirm': 'স্থায়ীভাবে মুছুন',
      'useProviderPicture': 'আমার Google ছবি ব্যবহার করুন',
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
      'teenPatti': 'তিন পাত্তি',
      'teenPattiTableNote': 'সিন, ব্লাইন্ড ও ভেরিয়েশন টেবিল',
      'viewGames': 'খেলা দেখুন',
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
      'taxPill': '{rate} ট্যাক্স',
      'taxPillNoRate': 'ট্যাক্স',
      'winningTaxTitle': 'জয়ের ট্যাক্স',
      'winningTaxLabel': 'জয়ের ট্যাক্স',
      'yourLevelLabel': 'আপনার লেভেল',
      'xpLabel': 'XP',
      'yourRateLabel': 'আপনার হার',
      'nextLevelLabel': 'পরের লেভেল',
      'levelName': 'লেভেল {n} · {title}',
      'levelLine': 'লেভেল {n} · {title} · {xp} XP',
      'nextLevelValue': '{xp} XP · {rate}',
      'topLevelNote': 'এটিই সর্বোচ্চ লেভেল।',
      'winningTaxOnlyWinner':
          'জয়ের ট্যাক্স শুধু প্রতিটি হাতের বিজয়ী দেন, যা জেতেন তার ওপর — পট থেকে নিজের দেওয়া চিপস বাদ দিয়ে।',
      'winningTaxFalls': 'আপনার লেভেল যত উঁচু, ট্যাক্স তত কম।',
      'ruleWinningTax':
          'প্রতিটি হাতের বিজয়ী যা জেতেন তার ওপর জয়ের ট্যাক্স দেন — পট থেকে নিজের দেওয়া চিপস বাদ দিয়ে — লেভেল 1-এ {top}, প্রতিটি পরের লেভেলে কম।',
      'winnerTaxLine': 'জয়ের ট্যাক্স −{tax}',
      'levelUp': 'লেভেল আপ! {level} — এখন আপনার জয়ের ট্যাক্স {rate}।',
      'xpToday': 'আজ {xp} / {cap} XP',
      'xpResetsIn': '{time} পরে রিসেট',
      'todayLabel': 'আজ',
      'levelUpOnly': 'লেভেল আপ! {level}',
      'allLevelsTitle': 'সব লেভেল',
      'levelTabMine': 'আমার লেভেল',
      'yourLevelTitle': 'আপনার লেভেল',
      'badgesTitle': 'ব্যাজ',
      'yourBadgesTitle': 'আপনার ব্যাজ',
      'avatarBadgeSemantics': '{badge} ব্যাজ',
      'taxColumn': 'ট্যাক্স',
      'levelYou': 'আপনি',
      'levelTaxLabel': 'লেভেল ট্যাক্স',
      'winningTaxLowest':
          'আপনার লেভেল আর ব্যাজের হারের মধ্যে যেটি সবচেয়ে কম, সেটিই দেন।',
      'rateSetByLevel': 'আপনার লেভেল অনুযায়ী',
      'rateSetByBadge': 'আপনার {badge} ব্যাজ অনুযায়ী',
      'xpDailyTitle': 'দৈনিক XP',
      'xpPlayMinutes': '{n} মিনিট সক্রিয় খেলুন',
      'xpWinBy': '{hand} দিয়ে জিতুন',
      'xpMissionDone': 'মিশন সম্পূর্ণ: {mission}',
      'xpGained': '+{xp} XP',
      'xpMissionFallback': 'দৈনিক XP মিশন',
      'xpBarTaxNow': 'এখন জয়ের ট্যাক্স {rate}',
      'xpListResets': 'এই তালিকা প্রতি {time}য় আবার শুরু হয়।',
      'xpEarned': 'পাওয়া গেছে',
      'xpDailyCap': 'প্রতি {time}য় সর্বোচ্চ {cap} XP।',
      'xpNeverExpires': 'XP আর লেভেল কখনো শেষ হয় না।',
      'levelNumber': 'লেভেল {n}',
      'xpOf': '{xp} / {max} XP',
      'xpToNext': '{title}-এর জন্য আরও {xp} XP',
      'levelNextLine': 'পরের: {level} · {xp} XP · {rate} ট্যাক্স',
      'taxNoteWinner':
          'শুধু হাতের বিজয়ী তাঁর নিট জয়ের উপর জয়ের ট্যাক্স দেন।',
      'taxNoteNet': 'নিট জয় = পট − তাতে আপনার নিজের চিপস।',
      'taxNoteBadge': 'সক্রিয় ব্যাজ আপনার ট্যাক্স আরও কমাতে পারে।',
      'badgeActive': 'সক্রিয়',
      'levelMax': 'সর্বোচ্চ লেভেল',
      'levelShort': 'লেভেল {n}',
      'levelBarSemantics': 'লেভেল {n}, {max}-এর মধ্যে {xp} XP',
      'levelBarTopSemantics': 'লেভেল {n}, {xp} XP, সর্বোচ্চ লেভেল',
      'levelHowTax': 'জয়ের ট্যাক্স কীভাবে লাগে',
      'badgeSetsRate': 'আপনার হার ঠিক করে',
      'badgeExpiresIn': '{time} পরে শেষ',
      'badgeExpired': 'মেয়াদ শেষ',
      'badgeYours': 'আপনার',
      'badgeRoyalHint':
          'রয়্যাল ব্যাজ আপনার জয়ের ট্যাক্স {rate} পর্যন্ত কমিয়ে দেয়।',
      'badgeSeeStore': 'ব্যাজ দেখুন',
      'badgesBesideLevel':
          'ব্যাজ আপনার লেভেলের পাশাপাশি থাকে; XP দিয়ে ব্যাজ পাওয়া যায় না।',
      'xpEarnedToday': 'আজ পাওয়া',
      'xpDailyComplete': 'দৈনিক XP সম্পূর্ণ',
      'xpDailyCompleteNote': 'আজকের সব XP পেয়ে গেছেন। রিসেটের পরে আবার পাবেন।',
      'xpResetsInCap': '{time} পরে রিসেট',
      'xpWindowIdle': 'আপনার দিন পরের হাত থেকে শুরু হবে।',
      'xpPlayTimeTitle': 'খেলার সময়',
      'xpPlayTimeNote':
          'সক্রিয় খেলা প্রতিটি ধাপে পৌঁছালে তার XP দিনে একবার পাবেন, আর সব যোগ হতে থাকে।',
      'xpMinutes': '{n} মিনিট',
      'xpWinHandsTitle': 'জেতার হাত',
      'xpWinHandsNote': 'এগুলোর প্রতিটি দিয়ে হাত জিতে তার XP পান, দিনে একবার।',
      'levelNextTag': 'পরের',
      'levelColumn': 'লেভেল',
      'unitDayShort': 'দি',
      'badgeAvailable': 'উপলব্ধ',
      'xpOtherTitle': 'XP পাওয়ার আরও উপায়',
      'xpOneTimeTitle': 'একবারের মিশন',
      'xpOneTimeNote':
          'প্রতিটি মিশন তার XP একবারই দেয়। এগুলো কখনো রিসেট হয় না।',
      'xpOneTimeDone': '{n} / {of} সম্পূর্ণ',
      'xpOneTimeTab': 'একবারের XP',
      'xpOneTimeNone': 'এখন কোনো একবারের মিশন নেই।',
      'xpMissionCompleted': 'সম্পূর্ণ',
      'xpMissionPlayHand1': '1টি হাত খেলুন',
      'xpMissionPlayHands': '{n}টি হাত খেলুন',
      'xpMissionWinHand1': '1টি হাত জিতুন',
      'xpMissionWinHands': '{n}টি হাত জিতুন',
      'xpMissionPlayGameHand1': '{game}-এর 1টি হাত খেলুন',
      'xpMissionPlayGameHands': '{game}-এর {n}টি হাত খেলুন',
      'xpMissionWinGameHand1': '{game}-এর 1টি হাত জিতুন',
      'xpMissionWinGameHands': '{game}-এর {n}টি হাত জিতুন',
      'xpMissionGames': '{n}টি আলাদা গেম খেলুন',
      'xpMissionGamesIn': '{game}-এর {n}টি আলাদা গেম খেলুন',
      'xpMissionVariations': '{n}টি আলাদা ভেরিয়েশন খেলুন',
      'badgeUntil': '{date} পর্যন্ত',
      'badgeEveryone': 'সবার জন্য',
      'badgeLasts': 'মেয়াদ {time}',
      'levelsUnavailable': 'লেভেলগুলো লোড করা যায়নি।',
      'ruleWinningTaxBadge': 'ব্যাজ এটি আরও কমাতে পারে।',
      'winningTaxFrom': '{amount}-এর কম জয়ে কোনো ট্যাক্স নেই।',
      'taxOnWinningsFrom': '{amount} বা তার বেশি জয়ে',
      'badgeLifetime': 'আজীবন',
      'badgeFree': 'বিনামূল্যে',
      'badgeTaxLine': '{rate} জয়ের ট্যাক্স',
      'badgeBought': '{badge} এখন {date} পর্যন্ত আপনার।',
      'variationRulesIntro':
          'প্রথম চালের খেলোয়াড় ১০ সেকেন্ড সময় পান হাতটি কোন নিয়মে ঠিক হবে তা বেছে নিতে; না বাছলে মুফলিস খেলা হয়। জোকার তাস সেই তাস হিসেবে গণ্য হয় যাতে আপনার হাত সবচেয়ে ভালো হয়। অন্যদের চিপস লুকানো থাকে এবং পটের কোনো সীমা নেই।',
      'variationChooseTitle': 'ভেরিয়েশন বেছে নিন',
      'pickTitle': 'আপনার তিনটি কার্ড বাছুন',
      'pickHint': 'খেলার জন্য আপনার পাঁচটি থেকে তিনটি কার্ড বাছুন',
      'pickConfirm': 'এই তিনটি খেলুন',
      'pickThreeCards': 'নিজের তিনটি কার্ডই বাছুন',
      'pickWasBest': 'আপনি সেরা কম্বিনেশনটি খেলেছেন',
      'pickNotBest': 'আপনি এটি খেলেছেন। সেরা ছিল:',
      'pickTimedOut': 'সময় শেষ — আপনার প্রথম তিনটি কার্ড খেলা হয়েছে',
      'pickYouPlayed': 'আপনি খেলেছেন',
      'pickTheBest': 'সেরা',
      'pickChoosing': '{name} কার্ড বাছছেন…',
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
      'sideshowPendingRefusal': 'আগে সাইডশোর উত্তরের জন্য অপেক্ষা করুন',
      'pickPendingRefusal':
          'একটু অপেক্ষা করুন: একজন খেলোয়াড় এখনও তাঁর তিনটি কার্ড বাছছেন',
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
      'autoPacked': 'আপনার পালা ফসকে গেছে — নিজে থেকে প্যাক হয়েছে',
      'missedYourTurn': 'আপনার পালা ফসকে গেছে',
      'lastWarning': 'শেষ সতর্কতা',
      'missOneMore': 'আর একটি পালা ফসকালে আপনি টেবিল ছাড়বেন',
      'missedTurnsCount': 'ফসকানো পালা: {max}টির মধ্যে {n}টি',
      'resumingTable': 'আপনার টেবিলে ফিরছি…',
      'pleaseWait': 'অনুগ্রহ করে অপেক্ষা করুন...',
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
      'block': 'ব্লক করুন',
      'unblock': 'আনব্লক করুন',
      'blockPlayersTitle': 'খেলোয়াড় ব্লক করুন',
      'blockNobody': 'এখনও টেবিলে আর কেউ নেই।',
      'saySomething': 'কিছু বলুন…',
      'tableMenu': 'টেবিল মেনু',
      'quickMessagesTitle': 'দ্রুত বার্তা',
      'quickMessagesTip': 'দ্রুত বার্তা পাঠান',
      'quickReorderHint': 'ক্রম বদলাতে চেপে ধরে টানুন',
      'quickAddMessage': 'বার্তা যোগ করুন',
      'quickCustomHint': 'আপনার বার্তা লিখুন',
      'quickCustomDuplicate': 'এই বার্তাটি আগে থেকেই আপনার তালিকায় আছে।',
      'quickCustomFull': 'আপনি নিজের 10টি পর্যন্ত বার্তা সেভ করতে পারেন।',
      'quickDeleteMessage': 'বার্তা মুছুন',
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
      'priceLabel': 'দাম',
      'youHaveLabel': 'আপনার কাছে',
      'unlockBody': '{name} এর দাম {cost} চিপস। এখনই আনলক করে ব্যবহার করবেন?',
      'unlockBodyDiamond':
          '{name} এর দাম {cost} ডায়মন্ড। এখনই আনলক করে ব্যবহার করবেন?',
      'pictureUnlocked': 'আনলক',
      'pictureOwned': 'আপনার',
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
      'timeMonth': '{n} মাস',
      'timeMonths': '{n} মাস',
      'timeYear': '{n} বছর',
      'timeYears': '{n} বছর',
      'friendsFor': '{time} ধরে বন্ধু',
      'friendsJustNow': 'এইমাত্র বন্ধু হয়েছেন',
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
      'accountDisabledTitle': 'অ্যাকাউন্ট নিষ্ক্রিয়',
      'accountDisabledBody':
          'আপনার অ্যাকাউন্ট নিষ্ক্রিয় করা হয়েছে। অনুগ্রহ করে সাপোর্টের সঙ্গে যোগাযোগ করুন।',
      'googlePhoto': 'Google ছবি',
      'ownPhoto': 'আপনার ছবি',
      'sessionReplacedTitle': 'অন্য ডিভাইসে সাইন ইন হয়েছে',
      'sessionReplacedBody':
          'কেউ অন্য একটি ডিভাইসে আপনার অ্যাকাউন্টে সাইন ইন করেছেন, তাই এখানে আপনাকে সাইন আউট করা হয়েছে। এই ফোনে খেলতে আবার সাইন ইন করুন — তখন অন্য ডিভাইসটি সাইন আউট হয়ে যাবে।',
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
      'useSocialPicture': 'আমার Google ছবি ব্যবহার করুন',
      'guestNoSocial': 'নিজের ছবি ব্যবহার করতে Google দিয়ে সাইন ইন করুন।',

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
      'blindsTitle': 'ব্লাইন্ডস',
      'anteTitle': 'অ্যান্টি',
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
      'rulePokerStreets': 'বাজি প্রি-ফ্লপে, তারপর ফ্লপ, টার্ন ও রিভারে',
      'rulePokerBetTo':
          'বেট বা রেইজ এই স্ট্রিটের জন্য আপনার মোট অঙ্ক বলে, তার উপরে যোগ করা অঙ্ক নয়',
      'rulePokerDrawStreets': 'ড্র-এর আগে একবার আর পরে একবার বাজি',
      'rulePokerPlayBet':
          'প্লে করলে অ্যান্টির সমান দ্বিতীয় বাজি লাগে; ফোল্ড করলে অ্যান্টি ঘরের থাকে',
      'pokerTableRankingTitle': 'এখানে কোনটা কাকে হারায়',
      'pokerTableRankingIntro':
          'আপনার হাত মানে আপনার সেরা পাঁচটি তাস, এই ক্রমে।',
      'pokerThreeCardRankingIntro':
          'প্রত্যেকের তিনটি তাস, নিজস্ব ক্রমে — পাঁচ তাসের ক্রম নয়, তিন পাত্তিরও নয়।',
      'rulePokerThreeCardRuns': 'A-K-Q সেরা রান আর A-2-3 সবচেয়ে ছোট',
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
      // Friends (owner, 26 Sep 2026)
      'friends': 'বন্ধুরা',
      'friendsOnlineCount': '{n} জন অনলাইন',
      'friendRequestWaiting': '1টি নতুন বন্ধুত্বের অনুরোধ',
      'friendRequestsWaiting': '{n}টি নতুন বন্ধুত্বের অনুরোধ',
      'yourPlayerId': 'আপনার খেলোয়াড় আইডি',
      'copyId': 'কপি করুন',
      'idCopied': 'কপি হয়েছে',
      'addFriend': 'বন্ধু যোগ করুন',
      'friendRequests': 'বন্ধুত্বের অনুরোধ',
      'noFriendRequests': 'কোনো বন্ধুত্বের অনুরোধ নেই',
      'noFriendsTitle': 'এখনও কোনো বন্ধু নেই',
      'noFriendsBody': 'খেলোয়াড় আইডি দিয়ে বন্ধুদের যোগ করুন।',
      'friendsLoadFailed': 'বন্ধুদের তালিকা লোড করা যায়নি।',
      'friendsRetry': 'আবার চেষ্টা করুন',
      'friendAccept': 'গ্রহণ করুন',
      'friendReject': 'প্রত্যাখ্যান করুন',
      'wantsToBeFriends': 'আপনার বন্ধু হতে চান',
      'presenceOnline': 'অনলাইন',
      'presenceOffline': 'অফলাইন',
      'playingNow': 'এখন খেলছেন',
      'addFriendHint': 'খেলোয়াড় আইডি দিয়ে খুঁজুন',
      'playerIdLabel': 'খেলোয়াড় আইডি',
      'searchPlayer': 'খুঁজুন',
      'requestSent': 'অনুরোধ পাঠানো হয়েছে',
      'thatsYou': 'এটি আপনি',
      'enterPlayerId': 'একটি খেলোয়াড় আইডি লিখুন।',
      'playerProfile': 'প্রোফাইল',
      'winRate': 'জয়ের হার',
      'removeFriend': 'বন্ধু সরান',
      'removeFriendQ': '{name}-কে আপনার বন্ধুদের থেকে সরাবেন?',
      'removeFriendBody':
          'পরে আপনি তাঁকে আবার বন্ধুত্বের অনুরোধ পাঠাতে পারবেন।',
      'removeFriendConfirm': 'সরান',
      'profileLoadFailed': 'এই প্রোফাইলটি লোড করা যায়নি।',
      'back': 'ফিরে যান',
      'friendAdded': '{name} এখন আপনার বন্ধু।',
      'friendRemoved': '{name} আর আপনার বন্ধু নন।',
      'friendRequestArrived': '{name} আপনাকে বন্ধুত্বের অনুরোধ পাঠিয়েছেন।',
      'friendRequestAtTable':
          '{name} আপনাকে বন্ধুত্বের অনুরোধ পাঠিয়েছেন। উত্তর দিতে তাঁর আসনে ট্যাপ করুন।',
      'friendAcceptedYours': '{name} আপনার বন্ধুত্বের অনুরোধ গ্রহণ করেছেন।',
      'friendMark': 'বন্ধু',
      'friendRefusePlayerNotFound': 'খেলোয়াড় পাওয়া যায়নি।',
      'friendRefuseInvalidId': 'এটি সঠিক খেলোয়াড় আইডি নয়।',
      'friendRefuseSelf': 'আপনি নিজেকে যোগ করতে পারবেন না।',
      'friendRefuseAlreadyFriends': 'আপনারা আগে থেকেই বন্ধু।',
      'friendRefuseAlreadySent': 'বন্ধুত্বের অনুরোধ আগেই পাঠানো হয়েছে।',
      'friendRefuseAlreadyReceived':
          'এই খেলোয়াড় আপনাকে আগেই অনুরোধ পাঠিয়েছেন — সেটি গ্রহণ করুন।',
      'friendRefuseRequestGone': 'এই বন্ধুত্বের অনুরোধটি আর নেই।',
      'friendRefuseNotPending':
          'এই বন্ধুত্বের অনুরোধের উত্তর আগেই দেওয়া হয়েছে।',
      'friendRefuseNotFriends': 'আপনি এই খেলোয়াড়ের বন্ধু নন।',
      'friendRefuseRateLimited':
          'অনেক বেশি চেষ্টা। একটু অপেক্ষা করে আবার চেষ্টা করুন।',
      'friendActionFailed': 'এটি হয়নি। আবার চেষ্টা করুন।',
      'addFriendHowTo':
          'আপনার বন্ধুর কাছে তাঁর খেলোয়াড় আইডি চেয়ে নিন — এটি তাঁর বন্ধুরা পাতার একেবারে উপরে থাকে।',
      'reportPlayer': 'খেলোয়াড়কে রিপোর্ট করুন',
      'reportWhy': 'আপনি কেন এই খেলোয়াড়কে রিপোর্ট করছেন?',
      'reportReasonCheating': 'প্রতারণা',
      'reportReasonHarassment': 'হয়রানি',
      'reportReasonAbusiveLanguage': 'অশালীন ভাষা',
      'reportReasonSpam': 'স্প্যাম',
      'reportReasonInappropriate': 'অনুচিত আচরণ',
      'reportReasonSuspicious': 'সন্দেহজনক খেলা',
      'reportReasonCollusion': 'যোগসাজশ',
      'reportReasonExploit': 'বাগের সুযোগ নেওয়া',
      'reportReasonOther': 'অন্যান্য',
      'reportDetails': 'বিবরণ',
      'reportDetailsHint': 'কী হয়েছিল? (ঐচ্ছিক)',
      'reportDetailsRequiredHint': 'কী হয়েছিল লিখুন (আবশ্যক)',
      'reportSubmit': 'রিপোর্ট পাঠান',
      'reportSubmitting': 'পাঠানো হচ্ছে…',
      'reportSubmitted': 'রিপোর্ট পাঠানো হয়েছে',
      'reportThanks': 'খেলাটিকে ন্যায্য রাখতে সাহায্য করার জন্য ধন্যবাদ।',
      'reportReview': 'আমাদের টিম রিপোর্টটি পর্যালোচনা করবে।',
      'reportDone': 'ঠিক আছে',
      'reportedTag': 'রিপোর্ট করা হয়েছে',
      'reportAlready': 'আপনি এই খেলোয়াড়কে আগেই রিপোর্ট করেছেন।',
      'reportLimited':
          'আপনি অনেক বেশি রিপোর্ট পাঠিয়েছেন। পরে আবার চেষ্টা করুন।',
      'reportLimitTitle': 'রিপোর্টের সীমা পূর্ণ',
      'reportLimitUsed': '{max}টির মধ্যে {used}টি রিপোর্ট ব্যবহৃত',
      'reportAgainIn': '{time} পরে আবার রিপোর্ট করতে পারবেন',
      'reportedTab': 'রিপোর্ট করা',
      'myReportsTitle': 'আপনি যাদের রিপোর্ট করেছেন',
      'noReportsYet': 'আপনি এখনও কাউকে রিপোর্ট করেননি।',
      'reportsLoadFailed': 'আপনার রিপোর্ট লোড করা যায়নি।',
      'reportedPlayerGone': 'মুছে ফেলা খেলোয়াড়',
      'reportStatusPending': 'অপেক্ষমাণ',
      'reportStatusUnderReview': 'পর্যালোচনায়',
      'reportStatusActionTaken': 'ব্যবস্থা নেওয়া হয়েছে',
      'reportStatusDismissed': 'খারিজ',
      'reportedOn': '{when} রিপোর্ট করা হয়েছে',
      'reportNotAtTable': 'এই খেলোয়াড় আর আপনার টেবিলে নেই।',
      'reportInvalidPlayer': 'এই খেলোয়াড়কে রিপোর্ট করা যাবে না।',
      'reportDescriptionRequired': 'অনুগ্রহ করে লিখুন কী হয়েছিল।',
      'reportDescriptionTooLong': 'বিবরণটি আরও ছোট রাখুন।',
      'reportNetworkError':
          'রিপোর্ট পাঠানো যায়নি। সংযোগ দেখে আবার চেষ্টা করুন।',
      'reportServerError': 'কিছু একটা ভুল হয়েছে। একটু পরে আবার চেষ্টা করুন।',
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
      'statsAll': 'બધા',
      'handsHeld': 'મળેલા હાથ',
      'variationsPlayed': 'રમેલા વેરિએશન',
      'statsPlayed': 'રમ્યા',
      'statsWon': 'જીત્યા',
      'statsNoVariations': 'હજી કોઈ વેરિએશન હાથ નથી',
      'statsPerformance': 'પ્રદર્શન',
      'statsAllGames': 'બધી ગેમ',
      'statsVariations': 'વેરિએશન ગેમ',
      'statsScopeLabel': 'આંકડા',
      'statsHandResults': 'હાથના પરિણામ',
      'statsNoHandResults': 'હજી કોઈ હાથનું પરિણામ નથી',
      'statsNoVariationGames': 'હજી સુધી કોઈ વેરિએશન ગેમ રમી નથી',
      'statsHandResultsHint': 'જોવા માટે તીન પત્તી અથવા વેરિએશન ગેમ પસંદ કરો',
      'statsVariationsHint': 'જોવા માટે વેરિએશન ગેમ પસંદ કરો',
      'luckyDrawChip': 'લકી ડ્રો',
      'luckyDrawTitle': 'લકી ડ્રો',
      'luckySpinReady': 'હમણાં ફેરવો',
      'luckySpinNow': 'હમણાં ફેરવો',
      'luckySpinning': 'ફરી રહ્યું છે…',
      'luckyNextSpin': 'આગલો સ્પિન',
      'luckyFreeSpin': 'મફત સ્પિન',
      'luckyNextFreeSpin': 'આગલો મફત સ્પિન',
      'luckyEvery': 'દર {time} પછી એક મફત સ્પિન.',
      'rewardsChip': 'રિવોર્ડ',
      'rewardsTitle': 'દૈનિક રિવોર્ડ',
      'rewardsCollect': 'હમણાં લો',
      'rewardsCollected': 'આજે લઈ લીધું',
      'rewardsCollectedTitle': 'દૈનિક રિવોર્ડ મળી ગયા!',
      'streakDayOne': '1 દિવસની સ્ટ્રીક',
      'streakDays': '{n} દિવસની સ્ટ્રીક',
      'streakStart': 'આજે તમારી સ્ટ્રીક શરૂ કરો',
      'calendarDayReward': 'દિવસ {n}નો રિવોર્ડ',
      'rewardModeStreak': 'લોગિન સ્ટ્રીક',
      'rewardModeCalendar': 'કૅલેન્ડર',
      'rewardStreakHint':
          'સીડી ચડવા દરરોજ લોગિન કરો. એક દિવસ ચૂક્યા તો સ્ટ્રીક ફરી દિવસ 1થી શરૂ થશે.',
      'rewardStreakHintNoReset':
          'સીડી ચડવા દરરોજ લોગિન કરો. ચૂકેલો દિવસ બસ ચૂકી જાય છે.',
      'rewardCalendarWeekHint':
          'અઠવાડિયાના દરેક દિવસનો એક રિવોર્ડ. ચૂકેલો દિવસ ચૂકી ગયો; બાકીના તમારી રાહ જુએ છે.',
      'rewardCalendarMonthHint':
          'મહિનાના દરેક દિવસનો એક રિવોર્ડ. ચૂકેલો દિવસ ચૂકી ગયો; બાકીના તમારી રાહ જુએ છે.',
      'rewardNext': 'આગલો રિવોર્ડ',
      'rewardDay': 'દિવસ {n}',
      'rewardToday': 'આજે',
      'rewardTileClaimed': 'મળી ગયો',
      'rewardTileLocked': 'લૉક',
      'rewardTileMissed': 'ચૂકી ગયો',
      'rewardNone': 'હમણાં કોઈ રિવોર્ડ ચાલતો નથી.',
      'rewardLoadFailed': 'રિવોર્ડ લોડ થઈ શક્યા નહીં.',
      'rewardLobbyOnly': 'રિવોર્ડ લોબીમાંથી લો, ટેબલ પર નહીં.',
      'rewardNothing': 'કોઈ રિવોર્ડ નહીં',
      'rewardAlreadyOwned': 'પહેલેથી તમારું',
      'rewardEmojiName': '{name} ઇમોજી',
      'rewardPictureName': '{name} ચિત્ર',
      'rewardTablePictureName': '{name} ટેબલ ચિત્ર',
      'rewardBadgeName': '{name} બેજ',
      'rewardBadgeDays': '{name} બેજ · {n} દિવસ',
      'rewardProgramWeeklyLogin': 'સાપ્તાહિક લોગિન સ્ટ્રીક',
      'rewardProgramMonthlyLogin': 'માસિક લોગિન સ્ટ્રીક',
      'rewardProgramWeeklyCalendar': 'સાપ્તાહિક કૅલેન્ડર રિવોર્ડ',
      'rewardProgramMonthlyCalendar': 'માસિક કૅલેન્ડર રિવોર્ડ',
      'todaysReward': 'આજનું રિવોર્ડ: {prize}',
      'rewardsAlso': 'સાથે: {list}',
      'todaysRewardTitle': 'આજનું રિવોર્ડ',
      'continueKey': 'ચાલુ રાખો',
      'weeklyFinal': 'અંતિમ',
      'weekday1': 'સોમ',
      'weekday2': 'મંગળ',
      'weekday3': 'બુધ',
      'weekday4': 'ગુરુ',
      'weekday5': 'શુક્ર',
      'weekday6': 'શનિ',
      'weekday7': 'રવિ',
      'luckyPrizes': 'ચક્ર પરના ઇનામ',
      'luckyNoPrize': 'કોઈ ઇનામ નથી',
      'luckyCongrats': 'અભિનંદન!',
      'luckyYouWon': 'તમે જીત્યા',
      'luckyNothingTitle': 'આગલી વખતે નસીબ સાથ આપશે!',
      'luckyNothingBody': 'ચક્ર ખાલી ખાના પર અટક્યું.',
      'luckyAlreadyOwned': 'આ પહેલેથી તમારો છે, તેથી કંઈ નવું અનલૉક થયું નથી.',
      'luckyPictureFor': '{time} માટે તમારો',
      'luckyWearNow': 'હમણાં વાપરો',
      'luckyLayNow': 'હમણાં વાપરો',
      'luckyProfilePicture': 'પ્રોફાઇલ ફોટો',
      'luckyTablePicture': 'ટેબલનો ફોટો',
      'luckyClosed': 'લકી ડ્રો હમણાં બંધ છે.',
      'luckyLoadFailed': 'લકી ડ્રો લોડ થઈ શક્યો નથી.',
      'luckyRetry': 'ફરી પ્રયાસ કરો',
      'luckyLobbyOnly': 'લકી ડ્રો લૉબીમાંથી ફેરવો.',
      'luckyNotReady': 'તમારો આગલો સ્પિન હજી તૈયાર નથી.',
      'countMissileOne': '1 મિસાઇલ',
      'countMissiles': '{n} મિસાઇલ',
      'welcomeAdded': 'સ્વાગત છે! તમારા ખાતામાં ઉમેરાયું: {items}',
      'welcomePlain': 'King Teen Patti માં આપનું સ્વાગત છે!',
      'countPictureOne': '1 ફોટો',
      'countPictures': '{n} ફોટા',
      'countTablePictureOne': '1 ટેબલનો ફોટો',
      'countTablePictures': '{n} ટેબલના ફોટા',
      'countEmojiOne': '1 ઇમોજી',
      'countEmojis': '{n} ઇમોજી',
      'rewardCollected': 'ઇનામ મળી ગયું!',
      'rewardPurchased': 'ચિપ્સ તમારા વૉલેટમાં છે. શુભકામના.',
      'rewardDiamondsPurchased': 'હીરા તમારા વૉલેટમાં છે. તેનાથી મિસાઇલ લો.',
      'tapToClose': 'બંધ કરવા ટૅપ કરો',
      'buyChips': 'ચિપ્સ ખરીદો',
      'shop': 'દુકાન',
      'comingSoon': 'ટૂંક સમયમાં',
      'updateTitle': 'અપડેટ જરૂરી છે',
      'updateBody':
          'રમવાનું ચાલુ રાખવા માટે King Teen Patti નું નવું વર્ઝન જરૂરી છે.',
      'updateNow': 'હમણાં અપડેટ કરો',
      'updateOpenStore': 'પ્લે સ્ટોર ખોલો',
      'updateOpenAppStore': 'એપ સ્ટોર ખોલો',
      'updateFailed': 'અપડેટ પૂરું થયું નથી. ફરી પ્રયાસ કરો.',
      // The app version gate (owner, 28 Sep 2026).
      'updateVersionLine': 'તમારું વર્ઝન {installed} · જરૂરી {required}',
      'updateStoreUnavailable':
          'સ્ટોર ખોલી શકાયો નથી. કૃપા કરીને તમારા એપ સ્ટોરમાંથી King Teen Patti અપડેટ કરો.',
      'softUpdateTitle': 'નવું વર્ઝન ઉપલબ્ધ છે',
      'softUpdateBody': 'King Teen Patti નું નવું વર્ઝન ઉપલબ્ધ છે.',
      'softUpdateLater': 'પછીથી',
      'maintenanceTitle': 'જાળવણી ચાલુ છે',
      'maintenanceBody':
          'King Teen Patti હાલમાં થોડા સમય માટે ઉપલબ્ધ નથી. કૃપા કરીને પછીથી ફરી પ્રયાસ કરો.',
      'maintenanceRetry': 'ફરી પ્રયાસ કરો',
      'purchaseNotLaunched': 'ખરીદી પૂર્ણ થઈ નહીં.',
      'storeTitle': 'ચિપ સ્ટોર',
      'storeBlurb': 'પૅક જેટલું મોટું, બોનસ એટલું મોટું.',
      'storeTabChips': 'ચિપ્સ',
      'storeTabPictures': 'ફોટા',
      'storeTabAnimated': 'એનિમેટેડ',
      'storePicturesBlurb': 'ચિપ્સ, હથોડી અથવા હીરાથી ફોટો અનલૉક કરો.',
      'storeAnimatedBlurb': 'હથોડી અથવા હીરાથી એનિમેટેડ ફોટો અનલૉક કરો.',
      'storeTabTables': 'ટેબલ',
      'storeTablesTitle': 'ટેબલના ફોટા',
      'storeTablesBlurb':
          'તમારું ટેબલ સજાવો — એક દેખાવ દિવસ માટે, એક રાત માટે.',
      'tableDefault': 'વહેતી ચિપ્સ',
      'tableDefaultHint': 'ડિફૉલ્ટ બૅકગ્રાઉન્ડ',
      'tableInUse': 'વપરાશમાં',
      'unlockTableTitle': 'આ ટેબલ અનલૉક કરવું છે?',
      'unlockTableBody':
          '{name} ની કિંમત {price} છે. હમણાં અનલૉક કરીને વાપરવું છે?',
      'unlockTableRentBody':
          '{name} ની કિંમત {price} છે અને {time} સુધી તમારું ટેબલ સજાવે છે. હમણાં અનલૉક કરીને વાપરવું છે?',
      'tableChipsLobbyOnly':
          'ચિપ્સની કિંમતવાળો ટેબલ ફોટો ફક્ત લૉબીમાં ખરીદી શકાય છે.',
      'priceChips': '{cost} ચિપ્સ',
      'priceDiamonds': '{cost} હીરા',
      'priceHammers': '{cost} હથોડી',
      'priceHammerOne': '1 હથોડી',
      'priceDiamondOne': '1 હીરો',
      'tablePokerNote':
          'પોકર ટેબલ પર ટેબલ ચિત્ર દેખાતું નથી — તે તમારા આગલા તીન પત્તી ટેબલ પર દેખાશે.',
      // Emojis (owner, 26 Sep 2026).
      'storeTabEmojis': 'ઇમોજી',
      'storeEmojisTitle': 'ઇમોજી',
      'storeEmojisBlurb': 'આખા ટેબલને મોકલવા માટે એનિમેટેડ ઇમોજી.',
      'storeTabBadges': 'બેજ',
      'storeBadgesTitle': 'બેજ',
      'storeBadgesBlurb': 'બેજ રહે ત્યાં સુધી તમારો જીત ટેક્સ ઓછો રહે છે.',
      'badgeContactSupport': 'સપોર્ટનો સંપર્ક કરો',
      'badgeContactTitle': '{badge} મેળવો',
      'badgeContactBody':
          '{badge} અમારી ટીમ આપે છે. અમને લખો, અમે તે મેળવવામાં તમારી મદદ કરીશું.',
      'badgeMailSubject': 'મને {badge} બેજ જોઈએ છે',
      'copyAddress': 'સરનામું કૉપિ કરો',
      'addressCopied': 'સરનામું કૉપિ થયું',
      'emojiShelfEmpty': 'હજી કોઈ ઇમોજી નથી.',
      'unlockEmojiTitle': 'આ ઇમોજી અનલૉક કરવું છે?',
      'unlockEmojiBody': '{name} ની કિંમત {price} છે. હમણાં અનલૉક કરવું છે?',
      'unlockEmojiRentBody':
          '{name} ની કિંમત {price} છે અને તે {time} સુધી તમારું છે. હમણાં અનલૉક કરવું છે?',
      'emojiChipsLobbyOnly':
          'ચિપ્સની કિંમતવાળું ઇમોજી ફક્ત લૉબીમાં ખરીદી શકાય છે.',
      'emojiOwnedNote': 'આ ઇમોજી તમારું છે — ટેબલ પર ઇમોજી બટનથી મોકલો.',
      'tableEmojis': 'ઇમોજી',
      'emojiSendHint': 'ટેબલને મોકલવા માટે ઇમોજી પર ટૅપ કરો.',
      'emojiUnlockMore': 'અનલૉક કરવા કોઈ એક પર ટૅપ કરો',
      'emojiNoneOwned': 'તમારી પાસે હજી કોઈ ઇમોજી નથી — નીચેથી એક અનલૉક કરો.',
      'emojiSentBy': '{name} એ {emoji} મોકલ્યું',
      'emojiLockedRefusal': 'પહેલાં સ્ટોરમાં આ ઇમોજી અનલૉક કરો.',
      'emojiUnknownRefusal': 'આ ઇમોજી અસ્તિત્વમાં નથી.',
      'emojiRetiredRefusal': 'આ ઇમોજી હવે ઉપલબ્ધ નથી.',
      'emojiUnaffordableRefusal':
          'આ ઇમોજી અનલૉક કરવા માટે તમારી પાસે પૂરતું નથી.',
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
      'forceSideshowTooLate':
          'મોડું થઈ ગયું — હવે એ સાઇડશો શક્ય નથી. કોઈ હથોડી વપરાઈ નથી.',
      'settings': 'સેટિંગ્સ',
      'language': 'ભાષા',
      'settingsSubtitle': 'રમતનો અનુભવ તમારી રીતે ગોઠવો',
      'settingsProfile': 'પ્રોફાઇલ',
      'settingsGameExperience': 'રમતનો અનુભવ',
      'settingsAccount': 'ખાતું',
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
      'deleteAccount': 'મારું ખાતું કાઢી નાખો',
      'deleteAccountTitle': 'ખાતું કાઢી નાખવું છે?',
      'deleteAccountBody':
          'આનાથી તમારું નામ, ચિત્ર, આંકડા અને તમારી બધી ચિપ્સ ભૂંસાઈ જશે, જે તમે ખરીદી હતી તે પણ. આ પાછું લઈ શકાતું નથી, અને કંઈ પણ નવા ખાતામાં આવશે નહીં.',
      'deleteAccountSeated': 'ખાતું કાઢી નાખતાં પહેલાં ટેબલ છોડો.',
      'deleteAccountConfirm': 'કાયમ માટે કાઢી નાખો',
      'useProviderPicture': 'મારો Google ફોટો વાપરો',
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
      'teenPatti': 'તીન પત્તી',
      'teenPattiTableNote': 'સીન, બ્લાઇન્ડ અને વેરિએશન ટેબલ',
      'viewGames': 'રમતો જુઓ',
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
      'taxPill': '{rate} ટેક્સ',
      'taxPillNoRate': 'ટેક્સ',
      'winningTaxTitle': 'જીત ટેક્સ',
      'winningTaxLabel': 'જીત ટેક્સ',
      'yourLevelLabel': 'તમારું લેવલ',
      'xpLabel': 'XP',
      'yourRateLabel': 'તમારો દર',
      'nextLevelLabel': 'આગલું લેવલ',
      'levelName': 'લેવલ {n} · {title}',
      'levelLine': 'લેવલ {n} · {title} · {xp} XP',
      'nextLevelValue': '{xp} XP · {rate}',
      'topLevelNote': 'આ સૌથી ઊંચું લેવલ છે.',
      'winningTaxOnlyWinner':
          'જીત ટેક્સ ફક્ત દરેક હાથનો વિજેતા ચૂકવે છે, પોતાની જીત પર — પોટમાંથી પોતે મૂકેલી ચિપ્સ બાદ કરીને.',
      'winningTaxFalls': 'તમારું લેવલ જેટલું ઊંચું, ટેક્સ એટલો ઓછો.',
      'ruleWinningTax':
          'દરેક હાથનો વિજેતા પોતાની જીત પર જીત ટેક્સ ચૂકવે છે — પોટમાંથી પોતે મૂકેલી ચિપ્સ બાદ કરીને — લેવલ 1 પર {top}, દરેક આગલા લેવલે ઓછો.',
      'winnerTaxLine': 'જીત ટેક્સ −{tax}',
      'levelUp': 'લેવલ અપ! {level} — હવે તમારો જીત ટેક્સ {rate} છે.',
      'xpToday': 'આજે {xp} / {cap} XP',
      'xpResetsIn': '{time} પછી રીસેટ',
      'todayLabel': 'આજે',
      'levelUpOnly': 'લેવલ અપ! {level}',
      'allLevelsTitle': 'બધા લેવલ',
      'levelTabMine': 'મારું લેવલ',
      'yourLevelTitle': 'તમારું લેવલ',
      'badgesTitle': 'બેજ',
      'yourBadgesTitle': 'તમારા બેજ',
      'avatarBadgeSemantics': '{badge} બેજ',
      'taxColumn': 'ટેક્સ',
      'levelYou': 'તમે',
      'levelTaxLabel': 'લેવલ ટેક્સ',
      'winningTaxLowest':
          'તમે તમારા લેવલ અને બેજના દરમાંથી સૌથી ઓછો દર ચૂકવો છો.',
      'rateSetByLevel': 'તમારા લેવલ મુજબ',
      'rateSetByBadge': 'તમારા {badge} બેજ મુજબ',
      'xpDailyTitle': 'દૈનિક XP',
      'xpPlayMinutes': '{n} મિનિટ સક્રિય રમો',
      'xpWinBy': '{hand}થી જીતો',
      'xpMissionDone': 'મિશન પૂર્ણ: {mission}',
      'xpGained': '+{xp} XP',
      'xpMissionFallback': 'દૈનિક XP મિશન',
      'xpBarTaxNow': 'હવે જીત ટેક્સ {rate}',
      'xpListResets': 'આ યાદી દર {time}માં ફરી શરૂ થાય છે.',
      'xpEarned': 'મળી ગયું',
      'xpDailyCap': 'દર {time}માં વધુમાં વધુ {cap} XP.',
      'xpNeverExpires': 'XP અને લેવલ ક્યારેય સમાપ્ત થતા નથી.',
      'levelNumber': 'લેવલ {n}',
      'xpOf': '{xp} / {max} XP',
      'xpToNext': '{title} માટે વધુ {xp} XP',
      'levelNextLine': 'આગલું: {level} · {xp} XP · {rate} ટેક્સ',
      'taxNoteWinner': 'ફક્ત હાથ જીતનાર પોતાની ચોખ્ખી જીત પર જીત ટેક્સ ભરે છે.',
      'taxNoteNet': 'ચોખ્ખી જીત = પોટ − તેમાં તમારી પોતાની ચિપ્સ.',
      'taxNoteBadge': 'સક્રિય બેજ તમારો ટેક્સ વધુ ઘટાડી શકે છે.',
      'badgeActive': 'સક્રિય',
      'levelMax': 'સૌથી ઊંચું લેવલ',
      'levelShort': 'લેવલ {n}',
      'levelBarSemantics': 'લેવલ {n}, {max} માંથી {xp} XP',
      'levelBarTopSemantics': 'લેવલ {n}, {xp} XP, સૌથી ઊંચું લેવલ',
      'levelHowTax': 'જીત ટેક્સ કેવી રીતે લાગે છે',
      'badgeSetsRate': 'તમારો દર નક્કી કરે છે',
      'badgeExpiresIn': '{time}માં સમાપ્ત',
      'badgeExpired': 'સમાપ્ત',
      'badgeYours': 'તમારો',
      'badgeRoyalHint': 'રોયલ બેજ તમારો જીત ટેક્સ {rate} સુધી ઘટાડે છે.',
      'badgeSeeStore': 'બેજ જુઓ',
      'badgesBesideLevel': 'બેજ તમારા લેવલની સાથે રહે છે; XPથી બેજ મળતો નથી.',
      'xpEarnedToday': 'આજે મળ્યું',
      'xpDailyComplete': 'દૈનિક XP પૂર્ણ',
      'xpDailyCompleteNote':
          'તમે આજનું બધું XP મેળવી લીધું. રીસેટ પછી ફરી મળશે.',
      'xpResetsInCap': '{time} પછી રીસેટ',
      'xpWindowIdle': 'તમારો દિવસ આગલા હાથથી શરૂ થશે.',
      'xpPlayTimeTitle': 'રમવાનો સમય',
      'xpPlayTimeNote':
          'સક્રિય રમત દરેક પડાવે પહોંચે તેમ તેનું XP દિવસમાં એક વાર મળે છે, અને બધું ઉમેરાતું જાય છે.',
      'xpMinutes': '{n} મિનિટ',
      'xpWinHandsTitle': 'જીતના હાથ',
      'xpWinHandsNote':
          'આમાંના દરેકથી હાથ જીતો અને તેનું XP મેળવો, દિવસમાં એક વાર.',
      'levelNextTag': 'આગલું',
      'levelColumn': 'લેવલ',
      'unitDayShort': 'દિ',
      'badgeAvailable': 'ઉપલબ્ધ',
      'xpOtherTitle': 'XP મેળવવાની વધુ રીતો',
      'xpOneTimeTitle': 'એક વારના મિશન',
      'xpOneTimeNote':
          'દરેક મિશન પોતાનું XP એક જ વાર આપે છે. તે ક્યારેય રીસેટ થતા નથી.',
      'xpOneTimeDone': '{n} / {of} પૂર્ણ',
      'xpOneTimeTab': 'એક વારનું XP',
      'xpOneTimeNone': 'હાલમાં કોઈ એક વારનું મિશન નથી.',
      'xpMissionCompleted': 'પૂર્ણ',
      'xpMissionPlayHand1': '1 હાથ રમો',
      'xpMissionPlayHands': '{n} હાથ રમો',
      'xpMissionWinHand1': '1 હાથ જીતો',
      'xpMissionWinHands': '{n} હાથ જીતો',
      'xpMissionPlayGameHand1': '{game}નો 1 હાથ રમો',
      'xpMissionPlayGameHands': '{game}ના {n} હાથ રમો',
      'xpMissionWinGameHand1': '{game}નો 1 હાથ જીતો',
      'xpMissionWinGameHands': '{game}ના {n} હાથ જીતો',
      'xpMissionGames': '{n} અલગ અલગ ગેમ રમો',
      'xpMissionGamesIn': '{game}ની {n} અલગ અલગ ગેમ રમો',
      'xpMissionVariations': '{n} અલગ અલગ વેરિએશન રમો',
      'badgeUntil': '{date} સુધી',
      'badgeEveryone': 'બધા માટે',
      'badgeLasts': '{time} સુધી',
      'levelsUnavailable': 'લેવલ લોડ થઈ શક્યા નહીં.',
      'ruleWinningTaxBadge': 'બેજ તેને વધુ ઘટાડી શકે છે.',
      'winningTaxFrom': '{amount}થી ઓછી જીત પર કોઈ ટેક્સ નથી.',
      'taxOnWinningsFrom': '{amount} કે તેથી વધુ જીત પર',
      'badgeLifetime': 'આજીવન',
      'badgeFree': 'મફત',
      'badgeTaxLine': '{rate} જીત ટેક્સ',
      'badgeBought': '{badge} હવે {date} સુધી તમારો છે.',
      'variationRulesIntro':
          'પહેલી ચાલવાળા ખેલાડીને હાથ કયા નિયમથી નક્કી થશે તે પસંદ કરવા 10 સેકન્ડ મળે છે; ન પસંદ કરે તો મુફલિસ રમાય છે. જોકર પત્તું એ પત્તું ગણાય છે જેનાથી તમારો હાથ સૌથી સારો બને. બીજાની ચિપ્સ છુપાયેલી રહે છે અને પોટની કોઈ મર્યાદા નથી.',
      'variationChooseTitle': 'વેરિએશન પસંદ કરો',
      'pickTitle': 'તમારા ત્રણ કાર્ડ પસંદ કરો',
      'pickHint': 'રમવા માટે તમારા પાંચમાંથી ત્રણ કાર્ડ પસંદ કરો',
      'pickConfirm': 'આ ત્રણ રમો',
      'pickThreeCards': 'તમારા જ ત્રણ કાર્ડ પસંદ કરો',
      'pickWasBest': 'તમે શ્રેષ્ઠ સંયોજન રમ્યા',
      'pickNotBest': 'તમે આ રમ્યા. શ્રેષ્ઠ આ હતું:',
      'pickTimedOut': 'સમય પૂરો — તમારા પહેલા ત્રણ કાર્ડ રમાયા',
      'pickYouPlayed': 'તમે રમ્યા',
      'pickTheBest': 'શ્રેષ્ઠ',
      'pickChoosing': '{name} કાર્ડ પસંદ કરી રહ્યા છે…',
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
      'sideshowPendingRefusal': 'પહેલાં સાઇડશોના જવાબની રાહ જુઓ',
      'pickPendingRefusal':
          'થોડી રાહ જુઓ: એક ખેલાડી હજી પોતાના ત્રણ કાર્ડ પસંદ કરી રહ્યો છે',
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
      'autoPacked': 'તમારો વારો ચૂકી ગયા — આપમેળે પૅક થયું',
      'missedYourTurn': 'તમારો વારો ચૂકી ગયા',
      'lastWarning': 'છેલ્લી ચેતવણી',
      'missOneMore': 'હજી એક વારો ચૂકશો તો તમે ટેબલ છોડશો',
      'missedTurnsCount': 'ચૂકેલા વારા: {max} માંથી {n}',
      'resumingTable': 'તમારા ટેબલ પર પાછા જઈ રહ્યા છીએ…',
      'pleaseWait': 'કૃપા કરીને રાહ જુઓ...',
      'welcomeBack': 'પરત સ્વાગત — તમે તમારા ટેબલ પર પાછા છો.',
      'unlock': 'અનલૉક કરો',
      'unlockTitle': 'આ ફોટો અનલૉક કરવો છે?',
      'priceLabel': 'કિંમત',
      'youHaveLabel': 'તમારી પાસે',
      'unlockBody':
          '{name} ની કિંમત {cost} ચિપ્સ છે. હમણાં અનલૉક કરીને વાપરવો?',
      'unlockBodyDiamond':
          '{name} ની કિંમત {cost} ડાયમંડ છે. હમણાં અનલૉક કરીને વાપરવો?',
      'pictureUnlocked': 'અનલૉક',
      'pictureOwned': 'તમારો',
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
      'timeMonth': '{n} મહિનો',
      'timeMonths': '{n} મહિના',
      'timeYear': '{n} વર્ષ',
      'timeYears': '{n} વર્ષ',
      'friendsFor': '{time}થી મિત્રો',
      'friendsJustNow': 'હમણાં જ મિત્રો બન્યા',
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
      'block': 'બ્લૉક કરો',
      'unblock': 'અનબ્લૉક કરો',
      'blockPlayersTitle': 'ખેલાડીઓને બ્લૉક કરો',
      'blockNobody': 'હજી ટેબલ પર બીજું કોઈ નથી.',
      'saySomething': 'કંઈક કહો…',
      'tableMenu': 'ટેબલ મેનૂ',
      'quickMessagesTitle': 'ઝટપટ સંદેશા',
      'quickMessagesTip': 'ઝટપટ સંદેશો મોકલો',
      'quickReorderHint': 'ક્રમ બદલવા દબાવીને ખેંચો',
      'quickAddMessage': 'સંદેશ ઉમેરો',
      'quickCustomHint': 'તમારો સંદેશ લખો',
      'quickCustomDuplicate': 'આ સંદેશ પહેલેથી તમારી યાદીમાં છે.',
      'quickCustomFull': 'તમે તમારા 10 સંદેશા સુધી સાચવી શકો છો.',
      'quickDeleteMessage': 'સંદેશ કાઢી નાખો',
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
      'accountDisabledTitle': 'ખાતું નિષ્ક્રિય છે',
      'accountDisabledBody':
          'તમારું ખાતું નિષ્ક્રિય કરવામાં આવ્યું છે. કૃપા કરીને સપોર્ટનો સંપર્ક કરો.',
      'googlePhoto': 'Google ફોટો',
      'ownPhoto': 'તમારો ફોટો',
      'sessionReplacedTitle': 'બીજા ઉપકરણ પર સાઇન ઇન થયું',
      'sessionReplacedBody':
          'કોઈએ બીજા ઉપકરણ પર તમારા ખાતામાં સાઇન ઇન કર્યું છે, તેથી તમને અહીંથી સાઇન આઉટ કરવામાં આવ્યા છે. આ ફોન પર રમવા માટે ફરીથી સાઇન ઇન કરો — ત્યારે બીજું ઉપકરણ સાઇન આઉટ થઈ જશે.',
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
      'useSocialPicture': 'મારો Google ફોટો વાપરો',
      'guestNoSocial': 'તમારો ફોટો વાપરવા Google થી સાઇન ઇન કરો.',

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
      'blindsTitle': 'બ્લાઇન્ડ્સ',
      'anteTitle': 'એન્ટી',
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
      'rulePokerBlinds':
          'દરેક હાથ {small} અને {big} ના બ્લાઇન્ડ્સથી શરૂ થાય છે',
      'rulePokerAnte': 'વહેંચતા પહેલાં દરેક {ante} ની એન્ટી મૂકે છે',
      'rulePokerBuyIn': 'ઓછામાં ઓછા {min} લઈને બેસો',
      'rulePokerHoleCards': 'દરેક ખેલાડીને {n} પત્તાં વહેંચાય છે',
      'rulePokerHoldemWin':
          'તમારાં બે પત્તાં અને બોર્ડનાં પાંચમાંથી શ્રેષ્ઠ પાંચ બનાવો',
      'rulePokerOmahaWin':
          'તમારાં ચારમાંથી બરાબર બે અને બોર્ડનાં ત્રણથી હાથ બને છે',
      'rulePokerDrawWin':
          'બેટ કરો, એક વાર {n} સુધી પત્તાં બદલો, પછી ફરી બેટ કરો',
      'rulePokerThreeCardWin':
          'એન્ટી જેટલું પ્લે કરો કે ફોલ્ડ; તમારાં ત્રણ પત્તાં ડીલર સાથે સરખાવાય છે',
      'rulePokerDealerQualifies':
          'ડીલરને રમવા ક્વીન-હાઈ જોઈએ; ન હોય તો તમારો પ્લે બેટ પાછો અને એન્ટી '
          'જીતે',
      'rulePokerBestHandWins':
          'શોડાઉનમાં શ્રેષ્ઠ હાથ પોટ લે છે; એકલો બચેલો ખેલાડી શોડાઉન વિના',
      'rulePokerStreets': 'દાવ પ્રી-ફ્લોપ, પછી ફ્લોપ, ટર્ન અને રિવર પર લાગે છે',
      'rulePokerBetTo':
          'બેટ કે રેઝ આ સ્ટ્રીટ માટે તમારી કુલ રકમ કહે છે, ઉપરથી ઉમેરેલી રકમ નહીં',
      'rulePokerDrawStreets': 'ડ્રો પહેલાં એક વાર અને પછી એક વાર દાવ',
      'rulePokerPlayBet':
          'પ્લે કરવાનો ખર્ચ એન્ટી જેટલો બીજો દાવ; ફોલ્ડ કરો તો એન્ટી ઘર પાસે રહે છે',
      'pokerTableRankingTitle': 'અહીં શું કોને હરાવે છે',
      'pokerTableRankingIntro':
          'તમારો હાથ એટલે તમારા શ્રેષ્ઠ પાંચ પત્તાં, આ ક્રમમાં.',
      'pokerThreeCardRankingIntro':
          'દરેકને ત્રણ પત્તાં, પોતાના ક્રમમાં — પાંચ પત્તાંનો ક્રમ નહીં, તીન પત્તીનો પણ નહીં.',
      'rulePokerThreeCardRuns': 'A-K-Q શ્રેષ્ઠ રન છે અને A-2-3 સૌથી નીચો',
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
      // Friends (owner, 26 Sep 2026)
      'friends': 'મિત્રો',
      'friendsOnlineCount': '{n} ઑનલાઇન',
      'friendRequestWaiting': '1 નવી મિત્રતાની વિનંતી',
      'friendRequestsWaiting': '{n} નવી મિત્રતાની વિનંતીઓ',
      'yourPlayerId': 'તમારી ખેલાડી આઈડી',
      'copyId': 'કૉપિ કરો',
      'idCopied': 'કૉપિ થઈ',
      'addFriend': 'મિત્ર ઉમેરો',
      'friendRequests': 'મિત્રતાની વિનંતીઓ',
      'noFriendRequests': 'કોઈ મિત્રતાની વિનંતી નથી',
      'noFriendsTitle': 'હજી કોઈ મિત્ર નથી',
      'noFriendsBody': 'મિત્રોને તેમની ખેલાડી આઈડીથી ઉમેરો.',
      'friendsLoadFailed': 'મિત્રોની યાદી લોડ થઈ શકી નથી.',
      'friendsRetry': 'ફરી પ્રયાસ કરો',
      'friendAccept': 'સ્વીકારો',
      'friendReject': 'નકારો',
      'wantsToBeFriends': 'તમારા મિત્ર બનવા માંગે છે',
      'presenceOnline': 'ઑનલાઇન',
      'presenceOffline': 'ઑફલાઇન',
      'playingNow': 'હમણાં રમી રહ્યા છે',
      'addFriendHint': 'ખેલાડી આઈડીથી શોધો',
      'playerIdLabel': 'ખેલાડી આઈડી',
      'searchPlayer': 'શોધો',
      'requestSent': 'વિનંતી મોકલાઈ',
      'thatsYou': 'આ તમે છો',
      'enterPlayerId': 'ખેલાડી આઈડી લખો.',
      'playerProfile': 'પ્રોફાઇલ',
      'winRate': 'જીતનો દર',
      'removeFriend': 'મિત્ર દૂર કરો',
      'removeFriendQ': '{name}ને તમારા મિત્રોમાંથી દૂર કરશો?',
      'removeFriendBody': 'તમે પછીથી તેમને ફરી મિત્રતાની વિનંતી મોકલી શકો છો.',
      'removeFriendConfirm': 'દૂર કરો',
      'profileLoadFailed': 'આ પ્રોફાઇલ લોડ થઈ શકી નથી.',
      'back': 'પાછા',
      'friendAdded': '{name} હવે તમારા મિત્ર છે.',
      'friendRemoved': '{name} હવે તમારા મિત્ર નથી.',
      'friendRequestArrived': '{name}એ તમને મિત્રતાની વિનંતી મોકલી છે.',
      'friendRequestAtTable':
          '{name}એ તમને મિત્રતાની વિનંતી મોકલી છે. જવાબ આપવા તેમની સીટ પર ટૅપ કરો.',
      'friendAcceptedYours': '{name}એ તમારી મિત્રતાની વિનંતી સ્વીકારી.',
      'friendMark': 'મિત્ર',
      'friendRefusePlayerNotFound': 'ખેલાડી મળ્યો નથી.',
      'friendRefuseInvalidId': 'આ સાચી ખેલાડી આઈડી નથી.',
      'friendRefuseSelf': 'તમે પોતાને ઉમેરી શકતા નથી.',
      'friendRefuseAlreadyFriends': 'તમે પહેલેથી જ મિત્રો છો.',
      'friendRefuseAlreadySent': 'મિત્રતાની વિનંતી પહેલેથી જ મોકલાઈ છે.',
      'friendRefuseAlreadyReceived':
          'આ ખેલાડીએ તમને પહેલેથી જ વિનંતી મોકલી છે — તેને સ્વીકારો.',
      'friendRefuseRequestGone': 'આ મિત્રતાની વિનંતી હવે નથી.',
      'friendRefuseNotPending':
          'આ મિત્રતાની વિનંતીનો જવાબ પહેલેથી જ અપાઈ ગયો છે.',
      'friendRefuseNotFriends': 'તમે આ ખેલાડીના મિત્ર નથી.',
      'friendRefuseRateLimited':
          'ઘણા બધા પ્રયાસો. થોડી રાહ જોઈને ફરી પ્રયાસ કરો.',
      'friendActionFailed': 'આ થઈ શક્યું નથી. ફરી પ્રયાસ કરો.',
      'addFriendHowTo':
          'તમારા મિત્ર પાસેથી તેમની ખેલાડી આઈડી માંગો — તે તેમના મિત્રો પેજમાં સૌથી ઉપર હોય છે.',
      'reportPlayer': 'ખેલાડીની જાણ કરો',
      'reportWhy': 'તમે આ ખેલાડીની જાણ કેમ કરી રહ્યા છો?',
      'reportReasonCheating': 'છેતરપિંડી',
      'reportReasonHarassment': 'હેરાનગતિ',
      'reportReasonAbusiveLanguage': 'અપમાનજનક ભાષા',
      'reportReasonSpam': 'સ્પામ',
      'reportReasonInappropriate': 'અયોગ્ય વર્તન',
      'reportReasonSuspicious': 'શંકાસ્પદ રમત',
      'reportReasonCollusion': 'મિલીભગત',
      'reportReasonExploit': 'બગનો લાભ લેવો',
      'reportReasonOther': 'અન્ય',
      'reportDetails': 'વિગતો',
      'reportDetailsHint': 'શું થયું? (વૈકલ્પિક)',
      'reportDetailsRequiredHint': 'શું થયું તે જણાવો (જરૂરી)',
      'reportSubmit': 'રિપોર્ટ મોકલો',
      'reportSubmitting': 'મોકલાઈ રહ્યું છે…',
      'reportSubmitted': 'રિપોર્ટ મોકલાઈ ગયો',
      'reportThanks': 'રમતને ન્યાયી રાખવામાં મદદ કરવા બદલ આભાર.',
      'reportReview': 'અમારી ટીમ આ રિપોર્ટની સમીક્ષા કરશે.',
      'reportDone': 'બરાબર',
      'reportedTag': 'જાણ કરી',
      'reportAlready': 'તમે આ ખેલાડીની જાણ પહેલેથી કરી છે.',
      'reportLimited':
          'તમે ઘણા બધા રિપોર્ટ મોકલ્યા છે. કૃપા કરીને પછી ફરી પ્રયાસ કરો.',
      'reportLimitTitle': 'રિપોર્ટની મર્યાદા પૂરી',
      'reportLimitUsed': '{max} માંથી {used} રિપોર્ટ વપરાયા',
      'reportAgainIn': '{time} પછી ફરી રિપોર્ટ કરી શકશો',
      'reportedTab': 'જાણ કરેલા',
      'myReportsTitle': 'તમે જેમની જાણ કરી',
      'noReportsYet': 'તમે હજી સુધી કોઈની જાણ કરી નથી.',
      'reportsLoadFailed': 'તમારા રિપોર્ટ લોડ થઈ શક્યા નહીં.',
      'reportedPlayerGone': 'કાઢી નાખેલો ખેલાડી',
      'reportStatusPending': 'બાકી',
      'reportStatusUnderReview': 'સમીક્ષામાં',
      'reportStatusActionTaken': 'પગલાં લેવાયાં',
      'reportStatusDismissed': 'રદ',
      'reportedOn': '{when}એ જાણ કરી',
      'reportNotAtTable': 'આ ખેલાડી હવે તમારા ટેબલ પર નથી.',
      'reportInvalidPlayer': 'આ ખેલાડીની જાણ કરી શકાતી નથી.',
      'reportDescriptionRequired': 'કૃપા કરીને જણાવો કે શું થયું.',
      'reportDescriptionTooLong': 'વિગતો થોડી ટૂંકી રાખો.',
      'reportNetworkError':
          'રિપોર્ટ મોકલી શકાયો નહીં. તમારું કનેક્શન તપાસીને ફરી પ્રયાસ કરો.',
      'reportServerError': 'કંઈક ખોટું થયું. થોડી વારમાં ફરી પ્રયાસ કરો.',
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
      'statsAll': 'ਸਾਰੇ',
      'handsHeld': 'ਮਿਲੇ ਹੱਥ',
      'variationsPlayed': 'ਖੇਡੇ ਵੇਰੀਏਸ਼ਨ',
      'statsPlayed': 'ਖੇਡੇ',
      'statsWon': 'ਜਿੱਤੇ',
      'statsNoVariations': 'ਅਜੇ ਕੋਈ ਵੇਰੀਏਸ਼ਨ ਹੱਥ ਨਹੀਂ',
      'statsPerformance': 'ਪ੍ਰਦਰਸ਼ਨ',
      'statsAllGames': 'ਸਾਰੀਆਂ ਗੇਮਾਂ',
      'statsVariations': 'ਵੇਰੀਏਸ਼ਨ ਗੇਮਾਂ',
      'statsScopeLabel': 'ਅੰਕੜੇ',
      'statsHandResults': 'ਹੱਥਾਂ ਦੇ ਨਤੀਜੇ',
      'statsNoHandResults': 'ਅਜੇ ਕੋਈ ਹੱਥ ਦਾ ਨਤੀਜਾ ਨਹੀਂ',
      'statsNoVariationGames': 'ਅਜੇ ਤੱਕ ਕੋਈ ਵੇਰੀਏਸ਼ਨ ਗੇਮ ਨਹੀਂ ਖੇਡੀ',
      'statsHandResultsHint': 'ਦੇਖਣ ਲਈ ਤੀਨ ਪੱਤੀ ਜਾਂ ਵੇਰੀਏਸ਼ਨ ਗੇਮਾਂ ਚੁਣੋ',
      'statsVariationsHint': 'ਦੇਖਣ ਲਈ ਵੇਰੀਏਸ਼ਨ ਗੇਮਾਂ ਚੁਣੋ',
      'luckyDrawChip': 'ਲੱਕੀ ਡਰਾਅ',
      'luckyDrawTitle': 'ਲੱਕੀ ਡਰਾਅ',
      'luckySpinReady': 'ਹੁਣੇ ਘੁਮਾਓ',
      'luckySpinNow': 'ਹੁਣੇ ਘੁਮਾਓ',
      'luckySpinning': 'ਘੁੰਮ ਰਿਹਾ ਹੈ…',
      'luckyNextSpin': 'ਅਗਲਾ ਸਪਿਨ',
      'luckyFreeSpin': 'ਮੁਫ਼ਤ ਸਪਿਨ',
      'luckyNextFreeSpin': 'ਅਗਲਾ ਮੁਫ਼ਤ ਸਪਿਨ',
      'luckyEvery': 'ਹਰ {time} ਬਾਅਦ ਇੱਕ ਮੁਫ਼ਤ ਸਪਿਨ।',
      'rewardsChip': 'ਰਿਵਾਰਡ',
      'rewardsTitle': 'ਰੋਜ਼ਾਨਾ ਰਿਵਾਰਡ',
      'rewardsCollect': 'ਹੁਣੇ ਲਓ',
      'rewardsCollected': 'ਅੱਜ ਲੈ ਲਿਆ',
      'rewardsCollectedTitle': 'ਰੋਜ਼ਾਨਾ ਰਿਵਾਰਡ ਮਿਲ ਗਏ!',
      'streakDayOne': '1 ਦਿਨ ਦੀ ਸਟ੍ਰੀਕ',
      'streakDays': '{n} ਦਿਨ ਦੀ ਸਟ੍ਰੀਕ',
      'streakStart': 'ਅੱਜ ਆਪਣੀ ਸਟ੍ਰੀਕ ਸ਼ੁਰੂ ਕਰੋ',
      'calendarDayReward': 'ਦਿਨ {n} ਦਾ ਰਿਵਾਰਡ',
      'rewardModeStreak': 'ਲਾਗਇਨ ਸਟ੍ਰੀਕ',
      'rewardModeCalendar': 'ਕੈਲੰਡਰ',
      'rewardStreakHint':
          'ਪੌੜੀ ਚੜ੍ਹਨ ਲਈ ਹਰ ਰੋਜ਼ ਲਾਗਇਨ ਕਰੋ। ਇੱਕ ਦਿਨ ਛੁੱਟਿਆ ਤਾਂ ਸਟ੍ਰੀਕ ਫਿਰ ਦਿਨ 1 ਤੋਂ ਸ਼ੁਰੂ ਹੋਵੇਗੀ।',
      'rewardStreakHintNoReset':
          'ਪੌੜੀ ਚੜ੍ਹਨ ਲਈ ਹਰ ਰੋਜ਼ ਲਾਗਇਨ ਕਰੋ। ਛੁੱਟਿਆ ਦਿਨ ਬਸ ਛੁੱਟ ਜਾਂਦਾ ਹੈ।',
      'rewardCalendarWeekHint':
          'ਹਫ਼ਤੇ ਦੇ ਹਰ ਦਿਨ ਦਾ ਇੱਕ ਰਿਵਾਰਡ। ਛੁੱਟਿਆ ਦਿਨ ਛੁੱਟ ਗਿਆ; ਬਾਕੀ ਤੁਹਾਡੀ ਉਡੀਕ ਕਰਦੇ ਹਨ।',
      'rewardCalendarMonthHint':
          'ਮਹੀਨੇ ਦੇ ਹਰ ਦਿਨ ਦਾ ਇੱਕ ਰਿਵਾਰਡ। ਛੁੱਟਿਆ ਦਿਨ ਛੁੱਟ ਗਿਆ; ਬਾਕੀ ਤੁਹਾਡੀ ਉਡੀਕ ਕਰਦੇ ਹਨ।',
      'rewardNext': 'ਅਗਲਾ ਰਿਵਾਰਡ',
      'rewardDay': 'ਦਿਨ {n}',
      'rewardToday': 'ਅੱਜ',
      'rewardTileClaimed': 'ਮਿਲ ਗਿਆ',
      'rewardTileLocked': 'ਲਾਕ',
      'rewardTileMissed': 'ਛੁੱਟ ਗਿਆ',
      'rewardNone': 'ਹੁਣ ਕੋਈ ਰਿਵਾਰਡ ਨਹੀਂ ਚੱਲ ਰਿਹਾ।',
      'rewardLoadFailed': 'ਰਿਵਾਰਡ ਲੋਡ ਨਹੀਂ ਹੋ ਸਕੇ।',
      'rewardLobbyOnly': 'ਰਿਵਾਰਡ ਲਾਬੀ ਤੋਂ ਲਓ, ਟੇਬਲ ’ਤੇ ਨਹੀਂ।',
      'rewardNothing': 'ਕੋਈ ਰਿਵਾਰਡ ਨਹੀਂ',
      'rewardAlreadyOwned': 'ਪਹਿਲਾਂ ਹੀ ਤੁਹਾਡਾ',
      'rewardEmojiName': '{name} ਇਮੋਜੀ',
      'rewardPictureName': '{name} ਤਸਵੀਰ',
      'rewardTablePictureName': '{name} ਟੇਬਲ ਤਸਵੀਰ',
      'rewardBadgeName': '{name} ਬੈਜ',
      'rewardBadgeDays': '{name} ਬੈਜ · {n} ਦਿਨ',
      'rewardProgramWeeklyLogin': 'ਹਫ਼ਤਾਵਾਰੀ ਲਾਗਇਨ ਸਟ੍ਰੀਕ',
      'rewardProgramMonthlyLogin': 'ਮਾਸਿਕ ਲਾਗਇਨ ਸਟ੍ਰੀਕ',
      'rewardProgramWeeklyCalendar': 'ਹਫ਼ਤਾਵਾਰੀ ਕੈਲੰਡਰ ਰਿਵਾਰਡ',
      'rewardProgramMonthlyCalendar': 'ਮਾਸਿਕ ਕੈਲੰਡਰ ਰਿਵਾਰਡ',
      'todaysReward': 'ਅੱਜ ਦਾ ਰਿਵਾਰਡ: {prize}',
      'rewardsAlso': 'ਨਾਲ ਹੀ: {list}',
      'todaysRewardTitle': 'ਅੱਜ ਦਾ ਰਿਵਾਰਡ',
      'continueKey': 'ਜਾਰੀ ਰੱਖੋ',
      'weeklyFinal': 'ਅੰਤਿਮ',
      'weekday1': 'ਸੋਮ',
      'weekday2': 'ਮੰਗਲ',
      'weekday3': 'ਬੁੱਧ',
      'weekday4': 'ਵੀਰ',
      'weekday5': 'ਸ਼ੁੱਕਰ',
      'weekday6': 'ਸ਼ਨੀ',
      'weekday7': 'ਐਤ',
      'luckyPrizes': 'ਪਹੀਏ ਦੇ ਇਨਾਮ',
      'luckyNoPrize': 'ਕੋਈ ਇਨਾਮ ਨਹੀਂ',
      'luckyCongrats': 'ਵਧਾਈਆਂ!',
      'luckyYouWon': 'ਤੁਸੀਂ ਜਿੱਤਿਆ',
      'luckyNothingTitle': 'ਅਗਲੀ ਵਾਰ ਕਿਸਮਤ ਸਾਥ ਦੇਵੇਗੀ!',
      'luckyNothingBody': 'ਪਹੀਆ ਖਾਲੀ ਖਾਨੇ ਉੱਤੇ ਰੁਕਿਆ।',
      'luckyAlreadyOwned':
          'ਇਹ ਪਹਿਲਾਂ ਤੋਂ ਤੁਹਾਡੀ ਹੈ, ਇਸ ਲਈ ਕੁਝ ਨਵਾਂ ਅਨਲੌਕ ਨਹੀਂ ਹੋਇਆ।',
      'luckyPictureFor': '{time} ਲਈ ਤੁਹਾਡੀ',
      'luckyWearNow': 'ਹੁਣੇ ਵਰਤੋ',
      'luckyLayNow': 'ਹੁਣੇ ਵਰਤੋ',
      'luckyProfilePicture': 'ਪ੍ਰੋਫਾਈਲ ਤਸਵੀਰ',
      'luckyTablePicture': 'ਟੇਬਲ ਦੀ ਤਸਵੀਰ',
      'luckyClosed': 'ਲੱਕੀ ਡਰਾਅ ਹੁਣ ਬੰਦ ਹੈ।',
      'luckyLoadFailed': 'ਲੱਕੀ ਡਰਾਅ ਲੋਡ ਨਹੀਂ ਹੋ ਸਕਿਆ।',
      'luckyRetry': 'ਮੁੜ ਕੋਸ਼ਿਸ਼ ਕਰੋ',
      'luckyLobbyOnly': 'ਲੱਕੀ ਡਰਾਅ ਲਾਬੀ ਤੋਂ ਘੁਮਾਓ।',
      'luckyNotReady': 'ਤੁਹਾਡਾ ਅਗਲਾ ਸਪਿਨ ਹਾਲੇ ਤਿਆਰ ਨਹੀਂ ਹੈ।',
      'countMissileOne': '1 ਮਿਜ਼ਾਈਲ',
      'countMissiles': '{n} ਮਿਜ਼ਾਈਲਾਂ',
      'welcomeAdded': 'ਜੀ ਆਇਆਂ ਨੂੰ! ਤੁਹਾਡੇ ਖਾਤੇ ਵਿੱਚ ਜੋੜਿਆ ਗਿਆ: {items}',
      'welcomePlain': 'King Teen Patti ਵਿੱਚ ਜੀ ਆਇਆਂ ਨੂੰ!',
      'countPictureOne': '1 ਤਸਵੀਰ',
      'countPictures': '{n} ਤਸਵੀਰਾਂ',
      'countTablePictureOne': '1 ਟੇਬਲ ਦੀ ਤਸਵੀਰ',
      'countTablePictures': '{n} ਟੇਬਲ ਦੀਆਂ ਤਸਵੀਰਾਂ',
      'countEmojiOne': '1 ਇਮੋਜੀ',
      'countEmojis': '{n} ਇਮੋਜੀ',
      'rewardCollected': 'ਇਨਾਮ ਮਿਲ ਗਿਆ!',
      'rewardPurchased': 'ਚਿੱਪਾਂ ਤੁਹਾਡੇ ਵਾਲਿਟ ਵਿੱਚ ਹਨ। ਸ਼ੁਭਕਾਮਨਾਵਾਂ।',
      'rewardDiamondsPurchased':
          'ਹੀਰੇ ਤੁਹਾਡੇ ਵਾਲਿਟ ਵਿੱਚ ਹਨ। ਇਨ੍ਹਾਂ ਨਾਲ ਮਿਜ਼ਾਈਲਾਂ ਲਓ।',
      'tapToClose': 'ਬੰਦ ਕਰਨ ਲਈ ਟੈਪ ਕਰੋ',
      'buyChips': 'ਚਿਪਸ ਖਰੀਦੋ',
      'shop': 'ਦੁਕਾਨ',
      'comingSoon': 'ਜਲਦੀ ਆ ਰਿਹਾ ਹੈ',
      'updateTitle': 'ਅੱਪਡੇਟ ਲਾਜ਼ਮੀ ਹੈ',
      'updateBody':
          'ਖੇਡਣਾ ਜਾਰੀ ਰੱਖਣ ਲਈ King Teen Patti ਦਾ ਨਵਾਂ ਵਰਜਨ ਲਾਜ਼ਮੀ ਹੈ।',
      'updateNow': 'ਹੁਣੇ ਅੱਪਡੇਟ ਕਰੋ',
      'updateOpenStore': 'ਪਲੇ ਸਟੋਰ ਖੋਲ੍ਹੋ',
      'updateOpenAppStore': 'ਐਪ ਸਟੋਰ ਖੋਲ੍ਹੋ',
      'updateFailed': 'ਅੱਪਡੇਟ ਪੂਰਾ ਨਹੀਂ ਹੋਇਆ। ਦੁਬਾਰਾ ਕੋਸ਼ਿਸ਼ ਕਰੋ।',
      // The app version gate (owner, 28 Sep 2026).
      'updateVersionLine': 'ਤੁਹਾਡਾ ਵਰਜਨ {installed} · ਲਾਜ਼ਮੀ {required}',
      'updateStoreUnavailable':
          'ਸਟੋਰ ਨਹੀਂ ਖੁੱਲ੍ਹ ਸਕਿਆ। ਕਿਰਪਾ ਕਰਕੇ ਆਪਣੇ ਐਪ ਸਟੋਰ ਤੋਂ King Teen Patti ਅੱਪਡੇਟ ਕਰੋ।',
      'softUpdateTitle': 'ਨਵਾਂ ਵਰਜਨ ਉਪਲਬਧ ਹੈ',
      'softUpdateBody': 'King Teen Patti ਦਾ ਇੱਕ ਨਵਾਂ ਵਰਜਨ ਉਪਲਬਧ ਹੈ।',
      'softUpdateLater': 'ਬਾਅਦ ਵਿੱਚ',
      'maintenanceTitle': 'ਮੁਰੰਮਤ ਚੱਲ ਰਹੀ ਹੈ',
      'maintenanceBody':
          'King Teen Patti ਹਾਲੇ ਕੁਝ ਸਮੇਂ ਲਈ ਉਪਲਬਧ ਨਹੀਂ ਹੈ। ਕਿਰਪਾ ਕਰਕੇ ਬਾਅਦ ਵਿੱਚ ਦੁਬਾਰਾ ਕੋਸ਼ਿਸ਼ ਕਰੋ।',
      'maintenanceRetry': 'ਦੁਬਾਰਾ ਕੋਸ਼ਿਸ਼ ਕਰੋ',
      'purchaseNotLaunched': 'ਖਰੀਦਦਾਰੀ ਪੂਰੀ ਨਹੀਂ ਹੋਈ।',
      'storeTitle': 'ਚਿੱਪ ਸਟੋਰ',
      'storeBlurb': 'ਪੈਕ ਜਿੰਨਾ ਵੱਡਾ, ਬੋਨਸ ਓਨਾ ਵੱਡਾ।',
      'storeTabChips': 'ਚਿਪਸ',
      'storeTabPictures': 'ਤਸਵੀਰਾਂ',
      'storeTabAnimated': 'ਐਨੀਮੇਟਿਡ',
      'storePicturesBlurb': 'ਚਿਪਸ, ਹਥੌੜਿਆਂ ਜਾਂ ਹੀਰਿਆਂ ਨਾਲ ਤਸਵੀਰ ਅਨਲੌਕ ਕਰੋ।',
      'storeAnimatedBlurb': 'ਹਥੌੜਿਆਂ ਜਾਂ ਹੀਰਿਆਂ ਨਾਲ ਐਨੀਮੇਟਿਡ ਤਸਵੀਰ ਅਨਲੌਕ ਕਰੋ।',
      'storeTabTables': 'ਟੇਬਲ',
      'storeTablesTitle': 'ਟੇਬਲ ਦੀਆਂ ਤਸਵੀਰਾਂ',
      'storeTablesBlurb': 'ਆਪਣਾ ਟੇਬਲ ਸਜਾਓ — ਇੱਕ ਰੂਪ ਦਿਨ ਲਈ, ਇੱਕ ਰਾਤ ਲਈ।',
      'tableDefault': 'ਵਗਦੀਆਂ ਚਿਪਸ',
      'tableDefaultHint': 'ਡਿਫ਼ਾਲਟ ਬੈਕਗ੍ਰਾਊਂਡ',
      'tableInUse': 'ਲੱਗੀ ਹੋਈ',
      'unlockTableTitle': 'ਇਹ ਟੇਬਲ ਅਨਲਾਕ ਕਰਨਾ ਹੈ?',
      'unlockTableBody':
          '{name} ਦੀ ਕੀਮਤ {price} ਹੈ। ਹੁਣੇ ਅਨਲਾਕ ਕਰਕੇ ਲਗਾਉਣਾ ਹੈ?',
      'unlockTableRentBody':
          '{name} ਦੀ ਕੀਮਤ {price} ਹੈ ਅਤੇ {time} ਤੱਕ ਤੁਹਾਡਾ ਟੇਬਲ ਸਜਾਉਂਦੀ ਹੈ। ਹੁਣੇ ਅਨਲਾਕ ਕਰਕੇ ਲਗਾਉਣਾ ਹੈ?',
      'tableChipsLobbyOnly':
          'ਚਿਪਸ ਦੀ ਕੀਮਤ ਵਾਲੀ ਟੇਬਲ ਤਸਵੀਰ ਸਿਰਫ਼ ਲੌਬੀ ਵਿੱਚ ਖਰੀਦੀ ਜਾ ਸਕਦੀ ਹੈ।',
      'priceChips': '{cost} ਚਿਪਸ',
      'priceDiamonds': '{cost} ਹੀਰੇ',
      'priceHammers': '{cost} ਹਥੌੜੇ',
      'priceHammerOne': '1 ਹਥੌੜਾ',
      'priceDiamondOne': '1 ਹੀਰਾ',
      'tablePokerNote':
          'ਪੋਕਰ ਟੇਬਲ ਉੱਤੇ ਟੇਬਲ ਤਸਵੀਰ ਨਹੀਂ ਦਿਖਦੀ — ਇਹ ਤੁਹਾਡੇ ਅਗਲੇ ਤੀਨ ਪੱਤੀ ਟੇਬਲ ਉੱਤੇ ਦਿਖੇਗੀ।',
      // Emojis (owner, 26 Sep 2026).
      'storeTabEmojis': 'ਇਮੋਜੀ',
      'storeEmojisTitle': 'ਇਮੋਜੀ',
      'storeEmojisBlurb': 'ਪੂਰੇ ਟੇਬਲ ਨੂੰ ਭੇਜਣ ਲਈ ਐਨੀਮੇਟਡ ਇਮੋਜੀ।',
      'storeTabBadges': 'ਬੈਜ',
      'storeBadgesTitle': 'ਬੈਜ',
      'storeBadgesBlurb': 'ਬੈਜ ਰਹਿਣ ਤੱਕ ਤੁਹਾਡਾ ਜਿੱਤ ਟੈਕਸ ਘੱਟ ਰਹਿੰਦਾ ਹੈ।',
      'badgeContactSupport': 'ਸਪੋਰਟ ਨਾਲ ਸੰਪਰਕ ਕਰੋ',
      'badgeContactTitle': '{badge} ਲਓ',
      'badgeContactBody':
          '{badge} ਸਾਡੀ ਟੀਮ ਦਿੰਦੀ ਹੈ। ਸਾਨੂੰ ਲਿਖੋ, ਅਸੀਂ ਇਸ ਨੂੰ ਲੈਣ ਵਿੱਚ ਤੁਹਾਡੀ ਮਦਦ ਕਰਾਂਗੇ।',
      'badgeMailSubject': 'ਮੈਨੂੰ {badge} ਬੈਜ ਚਾਹੀਦਾ ਹੈ',
      'copyAddress': 'ਪਤਾ ਕਾਪੀ ਕਰੋ',
      'addressCopied': 'ਪਤਾ ਕਾਪੀ ਹੋ ਗਿਆ',
      'emojiShelfEmpty': 'ਅਜੇ ਕੋਈ ਇਮੋਜੀ ਨਹੀਂ ਹੈ।',
      'unlockEmojiTitle': 'ਇਹ ਇਮੋਜੀ ਅਨਲਾਕ ਕਰਨਾ ਹੈ?',
      'unlockEmojiBody': '{name} ਦੀ ਕੀਮਤ {price} ਹੈ। ਹੁਣੇ ਅਨਲਾਕ ਕਰਨਾ ਹੈ?',
      'unlockEmojiRentBody':
          '{name} ਦੀ ਕੀਮਤ {price} ਹੈ ਅਤੇ ਇਹ {time} ਤੱਕ ਤੁਹਾਡਾ ਹੈ। ਹੁਣੇ ਅਨਲਾਕ ਕਰਨਾ ਹੈ?',
      'emojiChipsLobbyOnly':
          'ਚਿਪਸ ਦੀ ਕੀਮਤ ਵਾਲਾ ਇਮੋਜੀ ਸਿਰਫ਼ ਲਾਬੀ ਵਿੱਚ ਖਰੀਦਿਆ ਜਾ ਸਕਦਾ ਹੈ।',
      'emojiOwnedNote': 'ਇਹ ਇਮੋਜੀ ਤੁਹਾਡਾ ਹੈ — ਟੇਬਲ ਉੱਤੇ ਇਮੋਜੀ ਬਟਨ ਨਾਲ ਭੇਜੋ।',
      'tableEmojis': 'ਇਮੋਜੀ',
      'emojiSendHint': 'ਟੇਬਲ ਨੂੰ ਭੇਜਣ ਲਈ ਕਿਸੇ ਇਮੋਜੀ ਉੱਤੇ ਟੈਪ ਕਰੋ।',
      'emojiUnlockMore': 'ਅਨਲਾਕ ਕਰਨ ਲਈ ਕਿਸੇ ਇੱਕ ਉੱਤੇ ਟੈਪ ਕਰੋ',
      'emojiNoneOwned':
          'ਤੁਹਾਡੇ ਕੋਲ ਅਜੇ ਕੋਈ ਇਮੋਜੀ ਨਹੀਂ — ਹੇਠਾਂ ਤੋਂ ਇੱਕ ਅਨਲਾਕ ਕਰੋ।',
      'emojiSentBy': '{name} ਨੇ {emoji} ਭੇਜਿਆ',
      'emojiLockedRefusal': 'ਪਹਿਲਾਂ ਸਟੋਰ ਵਿੱਚ ਇਹ ਇਮੋਜੀ ਅਨਲਾਕ ਕਰੋ।',
      'emojiUnknownRefusal': 'ਇਹ ਇਮੋਜੀ ਮੌਜੂਦ ਨਹੀਂ ਹੈ।',
      'emojiRetiredRefusal': 'ਇਹ ਇਮੋਜੀ ਹੁਣ ਉਪਲਬਧ ਨਹੀਂ ਹੈ।',
      'emojiUnaffordableRefusal':
          'ਇਹ ਇਮੋਜੀ ਅਨਲਾਕ ਕਰਨ ਲਈ ਤੁਹਾਡੇ ਕੋਲ ਕਾਫ਼ੀ ਨਹੀਂ ਹੈ।',
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
      'forceSideshowTooLate':
          'ਦੇਰ ਹੋ ਗਈ — ਹੁਣ ਉਹ ਸਾਈਡਸ਼ੋ ਨਹੀਂ ਹੋ ਸਕਦਾ। ਕੋਈ ਹਥੌੜਾ ਖਰਚ ਨਹੀਂ ਹੋਇਆ।',
      'settings': 'ਸੈਟਿੰਗਾਂ',
      'language': 'ਭਾਸ਼ਾ',
      'settingsSubtitle': 'ਖੇਡ ਦਾ ਅਨੁਭਵ ਆਪਣੇ ਤਰੀਕੇ ਨਾਲ ਸਜਾਓ',
      'settingsProfile': 'ਪ੍ਰੋਫਾਈਲ',
      'settingsGameExperience': 'ਖੇਡ ਦਾ ਅਨੁਭਵ',
      'settingsAccount': 'ਖਾਤਾ',
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
      'deleteAccount': 'ਮੇਰਾ ਖਾਤਾ ਮਿਟਾਓ',
      'deleteAccountTitle': 'ਖਾਤਾ ਮਿਟਾਉਣਾ ਹੈ?',
      'deleteAccountBody':
          'ਇਸ ਨਾਲ ਤੁਹਾਡਾ ਨਾਂ, ਤਸਵੀਰ, ਅੰਕੜੇ ਅਤੇ ਤੁਹਾਡੀਆਂ ਸਾਰੀਆਂ ਚਿਪਸ ਮਿਟ ਜਾਣਗੀਆਂ, ਉਹ ਵੀ ਜੋ ਤੁਸੀਂ ਖਰੀਦੀਆਂ ਸਨ। ਇਹ ਵਾਪਸ ਨਹੀਂ ਹੋ ਸਕਦਾ, ਅਤੇ ਕੁਝ ਵੀ ਨਵੇਂ ਖਾਤੇ ਵਿੱਚ ਨਹੀਂ ਆਵੇਗਾ।',
      'deleteAccountSeated': 'ਖਾਤਾ ਮਿਟਾਉਣ ਤੋਂ ਪਹਿਲਾਂ ਟੇਬਲ ਛੱਡੋ।',
      'deleteAccountConfirm': 'ਹਮੇਸ਼ਾ ਲਈ ਮਿਟਾਓ',
      'useProviderPicture': 'ਮੇਰੀ Google ਤਸਵੀਰ ਵਰਤੋ',
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
      'teenPatti': 'ਤੀਨ ਪੱਤੀ',
      'teenPattiTableNote': 'ਸੀਨ, ਬਲਾਈਂਡ ਅਤੇ ਵੇਰੀਏਸ਼ਨ ਟੇਬਲ',
      'viewGames': 'ਖੇਡਾਂ ਵੇਖੋ',
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
      'taxPill': '{rate} ਟੈਕਸ',
      'taxPillNoRate': 'ਟੈਕਸ',
      'winningTaxTitle': 'ਜਿੱਤ ਟੈਕਸ',
      'winningTaxLabel': 'ਜਿੱਤ ਟੈਕਸ',
      'yourLevelLabel': 'ਤੁਹਾਡਾ ਲੈਵਲ',
      'xpLabel': 'XP',
      'yourRateLabel': 'ਤੁਹਾਡੀ ਦਰ',
      'nextLevelLabel': 'ਅਗਲਾ ਲੈਵਲ',
      'levelName': 'ਲੈਵਲ {n} · {title}',
      'levelLine': 'ਲੈਵਲ {n} · {title} · {xp} XP',
      'nextLevelValue': '{xp} XP · {rate}',
      'topLevelNote': 'ਇਹ ਸਭ ਤੋਂ ਉੱਚਾ ਲੈਵਲ ਹੈ।',
      'winningTaxOnlyWinner':
          'ਜਿੱਤ ਟੈਕਸ ਸਿਰਫ਼ ਹਰ ਹੱਥ ਦਾ ਜੇਤੂ ਦਿੰਦਾ ਹੈ, ਆਪਣੀ ਜਿੱਤ ਤੇ — ਪੌਟ ਵਿੱਚੋਂ ਆਪਣੇ ਲਾਏ ਚਿਪਸ ਘਟਾ ਕੇ।',
      'winningTaxFalls': 'ਤੁਹਾਡਾ ਲੈਵਲ ਜਿੰਨਾ ਉੱਚਾ, ਟੈਕਸ ਓਨਾ ਘੱਟ।',
      'ruleWinningTax':
          'ਹਰ ਹੱਥ ਦਾ ਜੇਤੂ ਆਪਣੀ ਜਿੱਤ ਤੇ ਜਿੱਤ ਟੈਕਸ ਦਿੰਦਾ ਹੈ — ਪੌਟ ਵਿੱਚੋਂ ਆਪਣੇ ਲਾਏ ਚਿਪਸ ਘਟਾ ਕੇ — ਲੈਵਲ 1 ਤੇ {top}, ਹਰ ਅਗਲੇ ਲੈਵਲ ਤੇ ਘੱਟ।',
      'winnerTaxLine': 'ਜਿੱਤ ਟੈਕਸ −{tax}',
      'levelUp': 'ਲੈਵਲ ਅੱਪ! {level} — ਹੁਣ ਤੁਹਾਡਾ ਜਿੱਤ ਟੈਕਸ {rate} ਹੈ।',
      'xpToday': 'ਅੱਜ {xp} / {cap} XP',
      'xpResetsIn': '{time} ਵਿੱਚ ਰੀਸੈੱਟ',
      'todayLabel': 'ਅੱਜ',
      'levelUpOnly': 'ਲੈਵਲ ਅੱਪ! {level}',
      'allLevelsTitle': 'ਸਾਰੇ ਲੈਵਲ',
      'levelTabMine': 'ਮੇਰਾ ਲੈਵਲ',
      'yourLevelTitle': 'ਤੁਹਾਡਾ ਲੈਵਲ',
      'badgesTitle': 'ਬੈਜ',
      'yourBadgesTitle': 'ਤੁਹਾਡੇ ਬੈਜ',
      'avatarBadgeSemantics': '{badge} ਬੈਜ',
      'taxColumn': 'ਟੈਕਸ',
      'levelYou': 'ਤੁਸੀਂ',
      'levelTaxLabel': 'ਲੈਵਲ ਟੈਕਸ',
      'winningTaxLowest':
          'ਤੁਸੀਂ ਆਪਣੇ ਲੈਵਲ ਅਤੇ ਬੈਜਾਂ ਦੀਆਂ ਦਰਾਂ ਵਿੱਚੋਂ ਸਭ ਤੋਂ ਘੱਟ ਦਰ ਦਿੰਦੇ ਹੋ।',
      'rateSetByLevel': 'ਤੁਹਾਡੇ ਲੈਵਲ ਮੁਤਾਬਕ',
      'rateSetByBadge': 'ਤੁਹਾਡੇ {badge} ਬੈਜ ਮੁਤਾਬਕ',
      'xpDailyTitle': 'ਰੋਜ਼ਾਨਾ XP',
      'xpPlayMinutes': '{n} ਮਿੰਟ ਸਰਗਰਮ ਖੇਡੋ',
      'xpWinBy': '{hand} ਨਾਲ ਜਿੱਤੋ',
      'xpMissionDone': 'ਮਿਸ਼ਨ ਪੂਰਾ: {mission}',
      'xpGained': '+{xp} XP',
      'xpMissionFallback': 'ਰੋਜ਼ਾਨਾ XP ਮਿਸ਼ਨ',
      'xpBarTaxNow': 'ਹੁਣ ਜਿੱਤ ਟੈਕਸ {rate}',
      'xpListResets': 'ਇਹ ਸੂਚੀ ਹਰ {time} ਵਿੱਚ ਮੁੜ ਸ਼ੁਰੂ ਹੁੰਦੀ ਹੈ।',
      'xpEarned': 'ਮਿਲ ਗਿਆ',
      'xpDailyCap': 'ਹਰ {time} ਵਿੱਚ ਵੱਧ ਤੋਂ ਵੱਧ {cap} XP।',
      'xpNeverExpires': 'XP ਅਤੇ ਲੈਵਲ ਕਦੇ ਖ਼ਤਮ ਨਹੀਂ ਹੁੰਦੇ।',
      'levelNumber': 'ਲੈਵਲ {n}',
      'xpOf': '{xp} / {max} XP',
      'xpToNext': '{title} ਲਈ {xp} XP ਹੋਰ',
      'levelNextLine': 'ਅਗਲਾ: {level} · {xp} XP · {rate} ਟੈਕਸ',
      'taxNoteWinner':
          'ਸਿਰਫ਼ ਹੱਥ ਜਿੱਤਣ ਵਾਲਾ ਆਪਣੀ ਸ਼ੁੱਧ ਜਿੱਤ ਤੇ ਜਿੱਤ ਟੈਕਸ ਦਿੰਦਾ ਹੈ।',
      'taxNoteNet': 'ਸ਼ੁੱਧ ਜਿੱਤ = ਪੌਟ − ਉਸ ਵਿੱਚ ਤੁਹਾਡੀਆਂ ਆਪਣੀਆਂ ਚਿਪਸ।',
      'taxNoteBadge': 'ਸਰਗਰਮ ਬੈਜ ਤੁਹਾਡਾ ਟੈਕਸ ਹੋਰ ਘਟਾ ਸਕਦਾ ਹੈ।',
      'badgeActive': 'ਸਰਗਰਮ',
      'levelMax': 'ਸਭ ਤੋਂ ਉੱਚਾ ਲੈਵਲ',
      'levelShort': 'ਲੈਵਲ {n}',
      'levelBarSemantics': 'ਲੈਵਲ {n}, {max} ਵਿੱਚੋਂ {xp} XP',
      'levelBarTopSemantics': 'ਲੈਵਲ {n}, {xp} XP, ਸਭ ਤੋਂ ਉੱਚਾ ਲੈਵਲ',
      'levelHowTax': 'ਜਿੱਤ ਟੈਕਸ ਕਿਵੇਂ ਲੱਗਦਾ ਹੈ',
      'badgeSetsRate': 'ਤੁਹਾਡੀ ਦਰ ਤੈਅ ਕਰਦਾ ਹੈ',
      'badgeExpiresIn': '{time} ਵਿੱਚ ਖ਼ਤਮ',
      'badgeExpired': 'ਖ਼ਤਮ ਹੋ ਗਿਆ',
      'badgeYours': 'ਤੁਹਾਡਾ',
      'badgeRoyalHint': 'ਰਾਇਲ ਬੈਜ ਤੁਹਾਡਾ ਜਿੱਤ ਟੈਕਸ {rate} ਤੱਕ ਘਟਾ ਦਿੰਦੇ ਹਨ।',
      'badgeSeeStore': 'ਬੈਜ ਵੇਖੋ',
      'badgesBesideLevel':
          'ਬੈਜ ਤੁਹਾਡੇ ਲੈਵਲ ਦੇ ਨਾਲ ਰਹਿੰਦੇ ਹਨ; XP ਨਾਲ ਬੈਜ ਨਹੀਂ ਮਿਲਦਾ।',
      'xpEarnedToday': 'ਅੱਜ ਮਿਲਿਆ',
      'xpDailyComplete': 'ਰੋਜ਼ਾਨਾ XP ਪੂਰਾ',
      'xpDailyCompleteNote':
          'ਤੁਸੀਂ ਅੱਜ ਦਾ ਸਾਰਾ XP ਲੈ ਲਿਆ। ਰੀਸੈੱਟ ਤੋਂ ਬਾਅਦ ਫਿਰ ਮਿਲੇਗਾ।',
      'xpResetsInCap': '{time} ਵਿੱਚ ਰੀਸੈੱਟ',
      'xpWindowIdle': 'ਤੁਹਾਡਾ ਦਿਨ ਅਗਲੇ ਹੱਥ ਨਾਲ ਸ਼ੁਰੂ ਹੋਵੇਗਾ।',
      'xpPlayTimeTitle': 'ਖੇਡਣ ਦਾ ਸਮਾਂ',
      'xpPlayTimeNote':
          'ਸਰਗਰਮ ਖੇਡ ਜਿਵੇਂ-ਜਿਵੇਂ ਹਰ ਪੜਾਅ ਤੇ ਪਹੁੰਚਦੀ ਹੈ, ਉਸਦਾ XP ਦਿਨ ਵਿੱਚ ਇੱਕ ਵਾਰ ਮਿਲਦਾ ਹੈ, ਅਤੇ ਸਭ ਜੁੜਦੇ ਜਾਂਦੇ ਹਨ।',
      'xpMinutes': '{n} ਮਿੰਟ',
      'xpWinHandsTitle': 'ਜਿੱਤ ਵਾਲੇ ਹੱਥ',
      'xpWinHandsNote':
          'ਇਹਨਾਂ ਵਿੱਚੋਂ ਹਰ ਇੱਕ ਨਾਲ ਹੱਥ ਜਿੱਤੋ ਅਤੇ ਉਸਦਾ XP ਲਵੋ, ਦਿਨ ਵਿੱਚ ਇੱਕ ਵਾਰ।',
      'levelNextTag': 'ਅਗਲਾ',
      'levelColumn': 'ਲੈਵਲ',
      'unitDayShort': 'ਦਿ',
      'badgeAvailable': 'ਉਪਲਬਧ',
      'xpOtherTitle': 'XP ਹਾਸਲ ਕਰਨ ਦੇ ਹੋਰ ਤਰੀਕੇ',
      'xpOneTimeTitle': 'ਇੱਕ ਵਾਰ ਦੇ ਮਿਸ਼ਨ',
      'xpOneTimeNote':
          'ਹਰ ਮਿਸ਼ਨ ਆਪਣਾ XP ਇੱਕੋ ਵਾਰ ਦਿੰਦਾ ਹੈ। ਇਹ ਕਦੇ ਰੀਸੈੱਟ ਨਹੀਂ ਹੁੰਦੇ।',
      'xpOneTimeDone': '{n} / {of} ਪੂਰੇ',
      'xpOneTimeTab': 'ਇੱਕ ਵਾਰ ਦਾ XP',
      'xpOneTimeNone': 'ਹੁਣ ਕੋਈ ਇੱਕ ਵਾਰ ਦਾ ਮਿਸ਼ਨ ਨਹੀਂ ਹੈ।',
      'xpMissionCompleted': 'ਪੂਰਾ ਹੋਇਆ',
      'xpMissionPlayHand1': '1 ਹੱਥ ਖੇਡੋ',
      'xpMissionPlayHands': '{n} ਹੱਥ ਖੇਡੋ',
      'xpMissionWinHand1': '1 ਹੱਥ ਜਿੱਤੋ',
      'xpMissionWinHands': '{n} ਹੱਥ ਜਿੱਤੋ',
      'xpMissionPlayGameHand1': '{game} ਦਾ 1 ਹੱਥ ਖੇਡੋ',
      'xpMissionPlayGameHands': '{game} ਦੇ {n} ਹੱਥ ਖੇਡੋ',
      'xpMissionWinGameHand1': '{game} ਦਾ 1 ਹੱਥ ਜਿੱਤੋ',
      'xpMissionWinGameHands': '{game} ਦੇ {n} ਹੱਥ ਜਿੱਤੋ',
      'xpMissionGames': '{n} ਵੱਖ-ਵੱਖ ਗੇਮਾਂ ਖੇਡੋ',
      'xpMissionGamesIn': '{game} ਦੀਆਂ {n} ਵੱਖ-ਵੱਖ ਗੇਮਾਂ ਖੇਡੋ',
      'xpMissionVariations': '{n} ਵੱਖ-ਵੱਖ ਵੇਰੀਏਸ਼ਨ ਖੇਡੋ',
      'badgeUntil': '{date} ਤੱਕ',
      'badgeEveryone': 'ਸਭ ਲਈ',
      'badgeLasts': '{time} ਤੱਕ',
      'levelsUnavailable': 'ਲੈਵਲ ਲੋਡ ਨਹੀਂ ਹੋ ਸਕੇ।',
      'ruleWinningTaxBadge': 'ਬੈਜ ਇਸ ਨੂੰ ਹੋਰ ਘਟਾ ਸਕਦਾ ਹੈ।',
      'winningTaxFrom': '{amount} ਤੋਂ ਘੱਟ ਜਿੱਤ ਤੇ ਕੋਈ ਟੈਕਸ ਨਹੀਂ।',
      'taxOnWinningsFrom': '{amount} ਜਾਂ ਵੱਧ ਜਿੱਤ ਤੇ',
      'badgeLifetime': 'ਉਮਰ ਭਰ',
      'badgeFree': 'ਮੁਫ਼ਤ',
      'badgeTaxLine': '{rate} ਜਿੱਤ ਟੈਕਸ',
      'badgeBought': '{badge} ਹੁਣ {date} ਤੱਕ ਤੁਹਾਡਾ ਹੈ।',
      'variationRulesIntro':
          'ਪਹਿਲੀ ਚਾਲ ਵਾਲੇ ਖਿਡਾਰੀ ਕੋਲ ਇਹ ਚੁਣਨ ਲਈ 10 ਸਕਿੰਟ ਹੁੰਦੇ ਹਨ ਕਿ ਹੱਥ ਕਿਸ ਨਿਯਮ ਨਾਲ ਤੈਅ ਹੋਵੇਗਾ; ਨਾ ਚੁਣੇ ਤਾਂ ਮੁਫ਼ਲਿਸ ਖੇਡਿਆ ਜਾਂਦਾ ਹੈ। ਜੋਕਰ ਪੱਤਾ ਉਹੀ ਪੱਤਾ ਗਿਣਿਆ ਜਾਂਦਾ ਹੈ ਜਿਸ ਨਾਲ ਤੁਹਾਡਾ ਹੱਥ ਸਭ ਤੋਂ ਵਧੀਆ ਬਣੇ। ਦੂਜਿਆਂ ਦੇ ਚਿਪਸ ਲੁਕੇ ਰਹਿੰਦੇ ਹਨ ਅਤੇ ਪੌਟ ਦੀ ਕੋਈ ਸੀਮਾ ਨਹੀਂ।',
      'variationChooseTitle': 'ਵੇਰੀਏਸ਼ਨ ਚੁਣੋ',
      'pickTitle': 'ਆਪਣੇ ਤਿੰਨ ਕਾਰਡ ਚੁਣੋ',
      'pickHint': 'ਖੇਡਣ ਲਈ ਆਪਣੇ ਪੰਜਾਂ ਵਿੱਚੋਂ ਤਿੰਨ ਕਾਰਡ ਚੁਣੋ',
      'pickConfirm': 'ਇਹ ਤਿੰਨ ਖੇਡੋ',
      'pickThreeCards': 'ਆਪਣੇ ਹੀ ਤਿੰਨ ਕਾਰਡ ਚੁਣੋ',
      'pickWasBest': 'ਤੁਸੀਂ ਸਭ ਤੋਂ ਵਧੀਆ ਸੁਮੇਲ ਖੇਡਿਆ',
      'pickNotBest': 'ਤੁਸੀਂ ਇਹ ਖੇਡਿਆ। ਸਭ ਤੋਂ ਵਧੀਆ ਇਹ ਸੀ:',
      'pickTimedOut': 'ਸਮਾਂ ਖ਼ਤਮ — ਤੁਹਾਡੇ ਪਹਿਲੇ ਤਿੰਨ ਕਾਰਡ ਖੇਡੇ ਗਏ',
      'pickYouPlayed': 'ਤੁਸੀਂ ਖੇਡਿਆ',
      'pickTheBest': 'ਸਭ ਤੋਂ ਵਧੀਆ',
      'pickChoosing': '{name} ਕਾਰਡ ਚੁਣ ਰਹੇ ਹਨ…',
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
      'sideshowPendingRefusal': 'ਪਹਿਲਾਂ ਸਾਈਡਸ਼ੋ ਦੇ ਜਵਾਬ ਦੀ ਉਡੀਕ ਕਰੋ',
      'pickPendingRefusal':
          'ਥੋੜ੍ਹਾ ਰੁਕੋ: ਇੱਕ ਖਿਡਾਰੀ ਅਜੇ ਆਪਣੇ ਤਿੰਨ ਕਾਰਡ ਚੁਣ ਰਿਹਾ ਹੈ',
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
      'autoPacked': 'ਤੁਹਾਡੀ ਵਾਰੀ ਖੁੰਝ ਗਈ — ਆਪਣੇ-ਆਪ ਪੈਕ ਹੋ ਗਿਆ',
      'missedYourTurn': 'ਤੁਹਾਡੀ ਵਾਰੀ ਖੁੰਝ ਗਈ',
      'lastWarning': 'ਆਖਰੀ ਚੇਤਾਵਨੀ',
      'missOneMore': 'ਇੱਕ ਹੋਰ ਵਾਰੀ ਖੁੰਝੀ ਤਾਂ ਤੁਸੀਂ ਟੇਬਲ ਛੱਡ ਦਿਓਗੇ',
      'unlock': 'ਅਨਲਾਕ ਕਰੋ',
      'unlockTitle': 'ਇਹ ਤਸਵੀਰ ਅਨਲਾਕ ਕਰਨੀ ਹੈ?',
      'priceLabel': 'ਕੀਮਤ',
      'youHaveLabel': 'ਤੁਹਾਡੇ ਕੋਲ',
      'unlockBody': '{name} ਦੀ ਕੀਮਤ {cost} ਚਿਪਸ ਹੈ। ਹੁਣੇ ਅਨਲਾਕ ਕਰਕੇ ਲਗਾਉਣੀ ਹੈ?',
      'unlockBodyDiamond':
          '{name} ਦੀ ਕੀਮਤ {cost} ਹੀਰੇ ਹੈ। ਹੁਣੇ ਅਨਲਾਕ ਕਰਕੇ ਲਗਾਉਣੀ ਹੈ?',
      'pictureUnlocked': 'ਅਨਲਾਕ',
      'pictureOwned': 'ਤੁਹਾਡੀ',
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
      'timeMonth': '{n} ਮਹੀਨਾ',
      'timeMonths': '{n} ਮਹੀਨੇ',
      'timeYear': '{n} ਸਾਲ',
      'timeYears': '{n} ਸਾਲ',
      'friendsFor': '{time} ਤੋਂ ਦੋਸਤ',
      'friendsJustNow': 'ਹੁਣੇ ਹੁਣੇ ਦੋਸਤ ਬਣੇ',
      'pictureKeeps': 'ਹਮੇਸ਼ਾ ਲਈ ਤੁਹਾਡੀ',
      'rentalLapsed': 'ਕਿਰਾਏ ਦੀ ਮਿਆਦ ਖਤਮ ਹੋ ਗਈ',
      'rentalEnds': 'ਮਿਆਦ ਖਤਮ: {date}',
      'rentalEnded': 'ਖਤਮ ਹੋਈ: {date}',
      'wear': 'ਲਗਾਓ',
      'wearing': 'ਲੱਗੀ ਹੋਈ ਹੈ',
      'missedTurnsCount': 'ਖੁੰਝੀਆਂ ਵਾਰੀਆਂ: {max} ਵਿੱਚੋਂ {n}',
      'resumingTable': 'ਤੁਹਾਡੇ ਟੇਬਲ ਤੇ ਵਾਪਸ ਜਾ ਰਹੇ ਹਾਂ…',
      'pleaseWait': 'ਕਿਰਪਾ ਕਰਕੇ ਉਡੀਕ ਕਰੋ...',
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
      'block': 'ਬਲਾਕ ਕਰੋ',
      'unblock': 'ਅਨਬਲਾਕ ਕਰੋ',
      'blockPlayersTitle': 'ਖਿਡਾਰੀਆਂ ਨੂੰ ਬਲਾਕ ਕਰੋ',
      'blockNobody': 'ਹਾਲੇ ਟੇਬਲ ਉੱਤੇ ਹੋਰ ਕੋਈ ਨਹੀਂ ਹੈ।',
      'saySomething': 'ਕੁਝ ਕਹੋ…',
      'tableMenu': 'ਟੇਬਲ ਮੀਨੂ',
      'quickMessagesTitle': 'ਝਟਪਟ ਸੁਨੇਹੇ',
      'quickMessagesTip': 'ਝਟਪਟ ਸੁਨੇਹਾ ਭੇਜੋ',
      'quickReorderHint': 'ਕ੍ਰਮ ਬਦਲਣ ਲਈ ਦਬਾ ਕੇ ਖਿੱਚੋ',
      'quickAddMessage': 'ਸੁਨੇਹਾ ਜੋੜੋ',
      'quickCustomHint': 'ਆਪਣਾ ਸੁਨੇਹਾ ਲਿਖੋ',
      'quickCustomDuplicate': 'ਇਹ ਸੁਨੇਹਾ ਪਹਿਲਾਂ ਹੀ ਤੁਹਾਡੀ ਸੂਚੀ ਵਿੱਚ ਹੈ।',
      'quickCustomFull': 'ਤੁਸੀਂ ਆਪਣੇ 10 ਸੁਨੇਹੇ ਤੱਕ ਸੰਭਾਲ ਸਕਦੇ ਹੋ।',
      'quickDeleteMessage': 'ਸੁਨੇਹਾ ਮਿਟਾਓ',
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
      'accountDisabledTitle': 'ਖਾਤਾ ਬੰਦ ਹੈ',
      'accountDisabledBody':
          'ਤੁਹਾਡਾ ਖਾਤਾ ਬੰਦ ਕਰ ਦਿੱਤਾ ਗਿਆ ਹੈ। ਕਿਰਪਾ ਕਰਕੇ ਸਪੋਰਟ ਨਾਲ ਸੰਪਰਕ ਕਰੋ।',
      'googlePhoto': 'Google ਫ਼ੋਟੋ',
      'ownPhoto': 'ਤੁਹਾਡੀ ਫ਼ੋਟੋ',
      'sessionReplacedTitle': "ਕਿਸੇ ਹੋਰ ਡਿਵਾਈਸ 'ਤੇ ਸਾਈਨ ਇਨ ਹੋਇਆ",
      'sessionReplacedBody':
          "ਕਿਸੇ ਨੇ ਹੋਰ ਡਿਵਾਈਸ 'ਤੇ ਤੁਹਾਡੇ ਖਾਤੇ ਵਿੱਚ ਸਾਈਨ ਇਨ ਕੀਤਾ ਹੈ, ਇਸ ਲਈ ਤੁਹਾਨੂੰ ਇੱਥੋਂ ਸਾਈਨ ਆਊਟ ਕਰ ਦਿੱਤਾ ਗਿਆ ਹੈ। ਇਸ ਫ਼ੋਨ 'ਤੇ ਖੇਡਣ ਲਈ ਦੁਬਾਰਾ ਸਾਈਨ ਇਨ ਕਰੋ — ਫਿਰ ਦੂਜੀ ਡਿਵਾਈਸ ਸਾਈਨ ਆਊਟ ਹੋ ਜਾਵੇਗੀ।",
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
      'useSocialPicture': 'ਮੇਰੀ Google ਤਸਵੀਰ ਵਰਤੋ',
      'guestNoSocial': 'ਆਪਣੀ ਤਸਵੀਰ ਵਰਤਣ ਲਈ Google ਨਾਲ ਸਾਈਨ ਇਨ ਕਰੋ।',

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
      'blindsTitle': 'ਬਲਾਈਂਡਸ',
      'anteTitle': 'ਐਂਟੀ',
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
      'rulePokerBlinds':
          'ਹਰ ਹੱਥ {small} ਅਤੇ {big} ਦੇ ਬਲਾਈਂਡਸ ਨਾਲ ਸ਼ੁਰੂ ਹੁੰਦਾ ਹੈ',
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
      'rulePokerStreets': 'ਦਾਅ ਪ੍ਰੀ-ਫਲੌਪ, ਫਿਰ ਫਲੌਪ, ਟਰਨ ਅਤੇ ਰਿਵਰ ਉੱਤੇ ਲੱਗਦੇ ਹਨ',
      'rulePokerBetTo':
          'ਬੈੱਟ ਜਾਂ ਰੇਜ਼ ਇਸ ਸਟ੍ਰੀਟ ਲਈ ਤੁਹਾਡੀ ਕੁੱਲ ਰਕਮ ਦੱਸਦਾ ਹੈ, ਉੱਤੋਂ ਜੋੜੀ ਰਕਮ ਨਹੀਂ',
      'rulePokerDrawStreets': 'ਡਰਾਅ ਤੋਂ ਪਹਿਲਾਂ ਇੱਕ ਵਾਰ ਅਤੇ ਬਾਅਦ ਇੱਕ ਵਾਰ ਦਾਅ',
      'rulePokerPlayBet':
          'ਪਲੇ ਕਰਨ ਦਾ ਖ਼ਰਚ ਐਂਟੀ ਜਿੰਨਾ ਦੂਜਾ ਦਾਅ; ਫ਼ੋਲਡ ਕਰੋ ਤਾਂ ਐਂਟੀ ਘਰ ਕੋਲ ਰਹਿ ਜਾਂਦੀ ਹੈ',
      'pokerTableRankingTitle': 'ਇੱਥੇ ਕੀ ਕਿਸ ਨੂੰ ਹਰਾਉਂਦਾ ਹੈ',
      'pokerTableRankingIntro':
          'ਤੁਹਾਡਾ ਹੱਥ ਤੁਹਾਡੇ ਸਭ ਤੋਂ ਵਧੀਆ ਪੰਜ ਪੱਤੇ ਹੁੰਦੇ ਹਨ, ਇਸ ਕ੍ਰਮ ਵਿੱਚ।',
      'pokerThreeCardRankingIntro':
          'ਹਰੇਕ ਨੂੰ ਤਿੰਨ ਪੱਤੇ, ਆਪਣੇ ਵੱਖਰੇ ਕ੍ਰਮ ਵਿੱਚ — ਨਾ ਪੰਜ ਪੱਤਿਆਂ ਦਾ ਕ੍ਰਮ, ਨਾ ਤੀਨ ਪੱਤੀ ਦਾ।',
      'rulePokerThreeCardRuns': 'A-K-Q ਸਭ ਤੋਂ ਵੱਡੀ ਰਨ ਹੈ ਅਤੇ A-2-3 ਸਭ ਤੋਂ ਛੋਟੀ',
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
      // Friends (owner, 26 Sep 2026)
      'friends': 'ਦੋਸਤ',
      'friendsOnlineCount': '{n} ਔਨਲਾਈਨ',
      'friendRequestWaiting': '1 ਨਵੀਂ ਦੋਸਤੀ ਦੀ ਬੇਨਤੀ',
      'friendRequestsWaiting': '{n} ਨਵੀਆਂ ਦੋਸਤੀ ਦੀਆਂ ਬੇਨਤੀਆਂ',
      'yourPlayerId': 'ਤੁਹਾਡੀ ਖਿਡਾਰੀ ਆਈਡੀ',
      'copyId': 'ਕਾਪੀ ਕਰੋ',
      'idCopied': 'ਕਾਪੀ ਹੋ ਗਈ',
      'addFriend': 'ਦੋਸਤ ਜੋੜੋ',
      'friendRequests': 'ਦੋਸਤੀ ਦੀਆਂ ਬੇਨਤੀਆਂ',
      'noFriendRequests': 'ਕੋਈ ਦੋਸਤੀ ਦੀ ਬੇਨਤੀ ਨਹੀਂ',
      'noFriendsTitle': 'ਅਜੇ ਕੋਈ ਦੋਸਤ ਨਹੀਂ',
      'noFriendsBody': 'ਦੋਸਤਾਂ ਨੂੰ ਉਨ੍ਹਾਂ ਦੀ ਖਿਡਾਰੀ ਆਈਡੀ ਨਾਲ ਜੋੜੋ।',
      'friendsLoadFailed': 'ਦੋਸਤਾਂ ਦੀ ਸੂਚੀ ਲੋਡ ਨਹੀਂ ਹੋ ਸਕੀ।',
      'friendsRetry': 'ਮੁੜ ਕੋਸ਼ਿਸ਼ ਕਰੋ',
      'friendAccept': 'ਸਵੀਕਾਰ ਕਰੋ',
      'friendReject': 'ਅਸਵੀਕਾਰ ਕਰੋ',
      'wantsToBeFriends': 'ਤੁਹਾਡਾ ਦੋਸਤ ਬਣਨਾ ਚਾਹੁੰਦੇ ਹਨ',
      'presenceOnline': 'ਔਨਲਾਈਨ',
      'presenceOffline': 'ਔਫ਼ਲਾਈਨ',
      'playingNow': 'ਹੁਣ ਖੇਡ ਰਹੇ ਹਨ',
      'addFriendHint': 'ਖਿਡਾਰੀ ਆਈਡੀ ਨਾਲ ਖੋਜੋ',
      'playerIdLabel': 'ਖਿਡਾਰੀ ਆਈਡੀ',
      'searchPlayer': 'ਖੋਜੋ',
      'requestSent': 'ਬੇਨਤੀ ਭੇਜੀ ਗਈ',
      'thatsYou': 'ਇਹ ਤੁਸੀਂ ਹੋ',
      'enterPlayerId': 'ਖਿਡਾਰੀ ਆਈਡੀ ਲਿਖੋ।',
      'playerProfile': 'ਪ੍ਰੋਫਾਈਲ',
      'winRate': 'ਜਿੱਤ ਦਰ',
      'removeFriend': 'ਦੋਸਤ ਹਟਾਓ',
      'removeFriendQ': 'ਕੀ {name} ਨੂੰ ਆਪਣੇ ਦੋਸਤਾਂ ਵਿੱਚੋਂ ਹਟਾਉਣਾ ਹੈ?',
      'removeFriendBody':
          'ਤੁਸੀਂ ਬਾਅਦ ਵਿੱਚ ਉਨ੍ਹਾਂ ਨੂੰ ਮੁੜ ਦੋਸਤੀ ਦੀ ਬੇਨਤੀ ਭੇਜ ਸਕਦੇ ਹੋ।',
      'removeFriendConfirm': 'ਹਟਾਓ',
      'profileLoadFailed': 'ਇਹ ਪ੍ਰੋਫਾਈਲ ਲੋਡ ਨਹੀਂ ਹੋ ਸਕੀ।',
      'back': 'ਵਾਪਸ',
      'friendAdded': '{name} ਹੁਣ ਤੁਹਾਡੇ ਦੋਸਤ ਹਨ।',
      'friendRemoved': '{name} ਹੁਣ ਤੁਹਾਡੇ ਦੋਸਤ ਨਹੀਂ ਹਨ।',
      'friendRequestArrived': '{name} ਨੇ ਤੁਹਾਨੂੰ ਦੋਸਤੀ ਦੀ ਬੇਨਤੀ ਭੇਜੀ ਹੈ।',
      'friendRequestAtTable':
          '{name} ਨੇ ਤੁਹਾਨੂੰ ਦੋਸਤੀ ਦੀ ਬੇਨਤੀ ਭੇਜੀ ਹੈ। ਜਵਾਬ ਦੇਣ ਲਈ ਉਨ੍ਹਾਂ ਦੀ ਸੀਟ ਉੱਤੇ ਟੈਪ ਕਰੋ।',
      'friendAcceptedYours': '{name} ਨੇ ਤੁਹਾਡੀ ਦੋਸਤੀ ਦੀ ਬੇਨਤੀ ਸਵੀਕਾਰ ਕਰ ਲਈ।',
      'friendMark': 'ਦੋਸਤ',
      'friendRefusePlayerNotFound': 'ਖਿਡਾਰੀ ਨਹੀਂ ਮਿਲਿਆ।',
      'friendRefuseInvalidId': 'ਇਹ ਸਹੀ ਖਿਡਾਰੀ ਆਈਡੀ ਨਹੀਂ ਹੈ।',
      'friendRefuseSelf': 'ਤੁਸੀਂ ਆਪਣੇ-ਆਪ ਨੂੰ ਨਹੀਂ ਜੋੜ ਸਕਦੇ।',
      'friendRefuseAlreadyFriends': 'ਤੁਸੀਂ ਪਹਿਲਾਂ ਹੀ ਦੋਸਤ ਹੋ।',
      'friendRefuseAlreadySent': 'ਦੋਸਤੀ ਦੀ ਬੇਨਤੀ ਪਹਿਲਾਂ ਹੀ ਭੇਜੀ ਜਾ ਚੁੱਕੀ ਹੈ।',
      'friendRefuseAlreadyReceived':
          'ਇਸ ਖਿਡਾਰੀ ਨੇ ਤੁਹਾਨੂੰ ਪਹਿਲਾਂ ਹੀ ਬੇਨਤੀ ਭੇਜੀ ਹੈ — ਇਸਨੂੰ ਸਵੀਕਾਰ ਕਰੋ।',
      'friendRefuseRequestGone': 'ਇਹ ਦੋਸਤੀ ਦੀ ਬੇਨਤੀ ਹੁਣ ਨਹੀਂ ਹੈ।',
      'friendRefuseNotPending':
          'ਇਸ ਦੋਸਤੀ ਦੀ ਬੇਨਤੀ ਦਾ ਜਵਾਬ ਪਹਿਲਾਂ ਹੀ ਦਿੱਤਾ ਜਾ ਚੁੱਕਾ ਹੈ।',
      'friendRefuseNotFriends': 'ਤੁਸੀਂ ਇਸ ਖਿਡਾਰੀ ਦੇ ਦੋਸਤ ਨਹੀਂ ਹੋ।',
      'friendRefuseRateLimited':
          'ਬਹੁਤ ਜ਼ਿਆਦਾ ਕੋਸ਼ਿਸ਼ਾਂ। ਥੋੜ੍ਹਾ ਰੁਕ ਕੇ ਮੁੜ ਕੋਸ਼ਿਸ਼ ਕਰੋ।',
      'friendActionFailed': 'ਇਹ ਨਹੀਂ ਹੋ ਸਕਿਆ। ਮੁੜ ਕੋਸ਼ਿਸ਼ ਕਰੋ।',
      'addFriendHowTo':
          'ਆਪਣੇ ਦੋਸਤ ਤੋਂ ਉਨ੍ਹਾਂ ਦੀ ਖਿਡਾਰੀ ਆਈਡੀ ਪੁੱਛੋ — ਇਹ ਉਨ੍ਹਾਂ ਦੇ ਦੋਸਤ ਪੰਨੇ ਦੇ ਸਭ ਤੋਂ ਉੱਪਰ ਹੁੰਦੀ ਹੈ।',
      'reportPlayer': 'ਖਿਡਾਰੀ ਦੀ ਰਿਪੋਰਟ ਕਰੋ',
      'reportWhy': 'ਤੁਸੀਂ ਇਸ ਖਿਡਾਰੀ ਦੀ ਰਿਪੋਰਟ ਕਿਉਂ ਕਰ ਰਹੇ ਹੋ?',
      'reportReasonCheating': 'ਧੋਖਾਧੜੀ',
      'reportReasonHarassment': 'ਪਰੇਸ਼ਾਨ ਕਰਨਾ',
      'reportReasonAbusiveLanguage': 'ਅਪਮਾਨਜਨਕ ਭਾਸ਼ਾ',
      'reportReasonSpam': 'ਸਪੈਮ',
      'reportReasonInappropriate': 'ਅਣਉਚਿਤ ਵਿਵਹਾਰ',
      'reportReasonSuspicious': 'ਸ਼ੱਕੀ ਖੇਡ',
      'reportReasonCollusion': 'ਮਿਲੀਭੁਗਤ',
      'reportReasonExploit': 'ਬੱਗ ਦਾ ਫ਼ਾਇਦਾ ਉਠਾਉਣਾ',
      'reportReasonOther': 'ਹੋਰ',
      'reportDetails': 'ਵੇਰਵਾ',
      'reportDetailsHint': 'ਕੀ ਹੋਇਆ? (ਵਿਕਲਪਿਕ)',
      'reportDetailsRequiredHint': 'ਦੱਸੋ ਕਿ ਕੀ ਹੋਇਆ (ਲਾਜ਼ਮੀ)',
      'reportSubmit': 'ਰਿਪੋਰਟ ਭੇਜੋ',
      'reportSubmitting': 'ਭੇਜੀ ਜਾ ਰਹੀ ਹੈ…',
      'reportSubmitted': 'ਰਿਪੋਰਟ ਭੇਜ ਦਿੱਤੀ ਗਈ',
      'reportThanks': 'ਖੇਡ ਨੂੰ ਨਿਰਪੱਖ ਰੱਖਣ ਵਿੱਚ ਮਦਦ ਲਈ ਧੰਨਵਾਦ।',
      'reportReview': 'ਸਾਡੀ ਟੀਮ ਇਸ ਰਿਪੋਰਟ ਦੀ ਜਾਂਚ ਕਰੇਗੀ।',
      'reportDone': 'ਠੀਕ ਹੈ',
      'reportedTag': 'ਰਿਪੋਰਟ ਕੀਤੀ',
      'reportAlready': 'ਤੁਸੀਂ ਇਸ ਖਿਡਾਰੀ ਦੀ ਰਿਪੋਰਟ ਪਹਿਲਾਂ ਹੀ ਕਰ ਚੁੱਕੇ ਹੋ।',
      'reportLimited':
          'ਤੁਸੀਂ ਬਹੁਤ ਸਾਰੀਆਂ ਰਿਪੋਰਟਾਂ ਭੇਜੀਆਂ ਹਨ। ਕਿਰਪਾ ਕਰਕੇ ਬਾਅਦ ਵਿੱਚ ਮੁੜ ਕੋਸ਼ਿਸ਼ ਕਰੋ।',
      'reportLimitTitle': 'ਰਿਪੋਰਟ ਦੀ ਸੀਮਾ ਪੂਰੀ',
      'reportLimitUsed': '{max} ਵਿੱਚੋਂ {used} ਰਿਪੋਰਟਾਂ ਵਰਤੀਆਂ',
      'reportAgainIn': '{time} ਬਾਅਦ ਮੁੜ ਰਿਪੋਰਟ ਕਰ ਸਕੋਗੇ',
      'reportedTab': 'ਰਿਪੋਰਟ ਕੀਤੇ',
      'myReportsTitle': 'ਤੁਸੀਂ ਜਿਨ੍ਹਾਂ ਦੀ ਰਿਪੋਰਟ ਕੀਤੀ',
      'noReportsYet': 'ਤੁਸੀਂ ਹਾਲੇ ਤੱਕ ਕਿਸੇ ਦੀ ਰਿਪੋਰਟ ਨਹੀਂ ਕੀਤੀ।',
      'reportsLoadFailed': 'ਤੁਹਾਡੀਆਂ ਰਿਪੋਰਟਾਂ ਲੋਡ ਨਹੀਂ ਹੋ ਸਕੀਆਂ।',
      'reportedPlayerGone': 'ਹਟਾਇਆ ਗਿਆ ਖਿਡਾਰੀ',
      'reportStatusPending': 'ਬਕਾਇਆ',
      'reportStatusUnderReview': 'ਸਮੀਖਿਆ ਅਧੀਨ',
      'reportStatusActionTaken': 'ਕਾਰਵਾਈ ਕੀਤੀ ਗਈ',
      'reportStatusDismissed': 'ਖਾਰਜ',
      'reportedOn': '{when} ਨੂੰ ਰਿਪੋਰਟ ਕੀਤੀ',
      'reportNotAtTable': 'ਇਹ ਖਿਡਾਰੀ ਹੁਣ ਤੁਹਾਡੇ ਟੇਬਲ ਉੱਤੇ ਨਹੀਂ ਹੈ।',
      'reportInvalidPlayer': 'ਇਸ ਖਿਡਾਰੀ ਦੀ ਰਿਪੋਰਟ ਨਹੀਂ ਕੀਤੀ ਜਾ ਸਕਦੀ।',
      'reportDescriptionRequired': 'ਕਿਰਪਾ ਕਰਕੇ ਦੱਸੋ ਕਿ ਕੀ ਹੋਇਆ।',
      'reportDescriptionTooLong': 'ਵੇਰਵਾ ਥੋੜ੍ਹਾ ਛੋਟਾ ਰੱਖੋ।',
      'reportNetworkError':
          'ਰਿਪੋਰਟ ਨਹੀਂ ਭੇਜੀ ਜਾ ਸਕੀ। ਆਪਣਾ ਕਨੈਕਸ਼ਨ ਜਾਂਚੋ ਅਤੇ ਮੁੜ ਕੋਸ਼ਿਸ਼ ਕਰੋ।',
      'reportServerError': 'ਕੁਝ ਗਲਤ ਹੋ ਗਿਆ। ਥੋੜ੍ਹੀ ਦੇਰ ਬਾਅਦ ਮੁੜ ਕੋਸ਼ਿਸ਼ ਕਰੋ।',
    },
  };
}
