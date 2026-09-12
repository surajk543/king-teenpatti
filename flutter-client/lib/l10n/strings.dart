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
  String get milestone => _('milestone');
  String get collect => _('collect');

  // --- collecting a reward
  String get rewardCollected => _('rewardCollected');
  String get rewardComeBack => _('rewardComeBack');
  String get rewardMilestoneAgain => _('rewardMilestoneAgain');
  String get rewardRefused => _('rewardRefused');
  String get rewardPurchased => _('rewardPurchased');
  String get tapToClose => _('tapToClose');

  // --- buying chips, not open yet
  String get buyChips => _('buyChips');

  /// The top bar's shop button.
  String get shop => _('shop');
  String get comingSoon => _('comingSoon');

  // --- the chip store
  String get storeTitle => _('storeTitle');
  String get storeBlurb => _('storeBlurb');
  String get storeBonus => _('storeBonus');
  String get storeNotLive => _('storeNotLive');
  String get posStarter => _('posStarter');
  String get posPopular => _('posPopular');
  String get posBestValue => _('posBestValue');
  String get posPremium => _('posPremium');
  String get comingSoonBody => _('comingSoonBody');
  String get handsToGo => _('handsToGo');
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
  String get serviceUnavailable => _('serviceUnavailable');
  String get soundLabel => _('soundLabel');
  String get vibrationLabel => _('vibrationLabel');
  String get useProviderPicture => _('useProviderPicture');
  String get pictureLocked => _('pictureLocked');

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
  String get accept => _('accept');
  String get decline => _('decline');
  String get sideshowDeclined => _('sideshowDeclined');
  String get sideshowTimedOut => _('sideshowTimedOut');
  String get sideshowCancelled => _('sideshowCancelled');
  String get sideshowYouLost => _('sideshowYouLost');
  String get sideshowYouWon => _('sideshowYouWon');
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
  String get winner => _('winner');
  String get tableChat => _('tableChat');
  String get saySomething => _('saySomething');
  String get tableMenu => _('tableMenu');
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
  String unlockBody(String name, String cost) => _('unlockBody')
      .replaceAll('{name}', name)
      .replaceAll('{cost}', cost);
  /// The word on a premium picture this player has already paid for.
  String get pictureUnlocked => _('pictureUnlocked');

  /// The caption under the big picture in Settings.
  String get tapToChangePicture => _('tapToChangePicture');

  /// Rental wording for a premium picture.
  String rentForDays(int days) =>
      _('rentForDays').replaceAll('{days}', '$days');
  String daysLeft(int days) => _('daysLeft').replaceAll('{days}', '$days');
  String unlockRentBody(String name, String cost, int days) =>
      _('unlockRentBody')
          .replaceAll('{name}', name)
          .replaceAll('{cost}', cost)
          .replaceAll('{days}', '$days');

  /// The two tiers, as section headings in the picture picker.
  String get pictureFree => _('pictureFree');
  String get picturePremium => _('picturePremium');
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
      'milestone': 'MILESTONE',
      'collect': 'Collect',
      'rewardCollected': 'Reward collected!',
      'rewardComeBack': 'Come again after 4 hours.',
      'rewardPurchased': 'The chips are in your wallet. Good luck.',
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
      'storeBonus': 'BONUS',
      'storeNotLive': 'Payments are not live yet — nothing was charged.',
      'posStarter': 'STARTER',
      'posPopular': 'POPULAR',
      'posBestValue': 'BEST VALUE',
      'posPremium': 'PREMIUM',
      'comingSoonBody':
          'Buying chips is not open yet. Collect your rewards in the meantime.',
      'handsToGo': 'hands to go',
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
      'serviceUnavailable': 'Service not available',
      'soundLabel': 'Sound',
      'vibrationLabel': 'Vibration',
      'useProviderPicture': 'Use my Google/Facebook picture',
      'pictureLocked': 'It cannot change once you sit at a table.',
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
      'sideshowRunning': 'Sideshow',
      'accept': 'Accept',
      'decline': 'Decline',
      'sideshowDeclined': 'Your sideshow was declined',
      'sideshowTimedOut': 'No answer — the sideshow lapsed',
      'sideshowCancelled': 'The sideshow was called off',
      'sideshowYouLost': 'Your hand was lower — you packed',
      'sideshowYouWon': 'Your hand was higher — they packed',
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
      'tableLost': 'The table closed while you were away.',
      'winner': 'Winner',
      'tableChat': 'Table chat',
      'saySomething': 'Say something…',
      'tableMenu': 'Table menu',
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
      'pictureUnlocked': 'Unlocked',
      'tapToChangePicture': 'Tap to change your picture',
      'rentForDays': '{days} days',
      'daysLeft': '{days}d left',
      'unlockRentBody': '{name} costs {cost} chips and is yours for {days} days. Unlock it and wear it now?',
      'pictureFree': 'Free',
      'picturePremium': 'Premium',
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
      'milestone': 'माइलस्टोन',
      'collect': 'लें',
      'rewardCollected': 'इनाम मिल गया!',
      'rewardComeBack': '4 घंटे बाद फिर आइए।',
      'rewardPurchased': 'चिप्स आपके वॉलेट में हैं। शुभकामनाएँ।',
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
      'storeBonus': 'बोनस',
      'storeNotLive': 'भुगतान अभी चालू नहीं है — कोई शुल्क नहीं लिया गया।',
      'posStarter': 'शुरुआत',
      'posPopular': 'लोकप्रिय',
      'posBestValue': 'सबसे बढ़िया',
      'posPremium': 'प्रीमियम',
      'comingSoonBody':
          'चिप्स खरीदना अभी शुरू नहीं हुआ है। तब तक अपने इनाम लेते रहें।',
      'handsToGo': 'हाथ बाकी',
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
      'serviceUnavailable': 'सेवा उपलब्ध नहीं है',
      'soundLabel': 'आवाज़',
      'vibrationLabel': 'कंपन',
      'useProviderPicture': 'मेरी Google/Facebook तस्वीर लगाएँ',
      'pictureLocked': 'टेबल पर बैठने के बाद इसे बदला नहीं जा सकता।',
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
      'sideshowRunning': 'साइडशो',
      'accept': 'स्वीकारें',
      'decline': 'मना करें',
      'sideshowDeclined': 'आपका साइडशो मना कर दिया गया',
      'sideshowTimedOut': 'कोई जवाब नहीं — साइडशो रद्द',
      'sideshowCancelled': 'साइडशो रद्द हो गया',
      'sideshowYouLost': 'आपके पत्ते कमज़ोर थे — आप पैक हुए',
      'sideshowYouWon': 'आपके पत्ते बेहतर थे — वे पैक हुए',
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
      'tableLost': 'आप दूर थे तब टेबल बंद हो गई।',
      'winner': 'विजेता',
      'tableChat': 'टेबल चैट',
      'saySomething': 'कुछ कहें…',
      'tableMenu': 'टेबल मेनू',
      'yourChips': 'आपके चिप्स',
      'maxPot': 'अधिकतम पॉट',
      'nightMode': 'रात मोड',
      'dayMode': 'दिन मोड',
      'appearance': 'रूप',
      'themeSystem': 'सिस्टम',
      'unlock': 'अनलॉक करें',
      'unlockTitle': 'यह तस्वीर अनलॉक करें?',
      'unlockBody': '{name} की कीमत {cost} चिप्स है। अभी अनलॉक करके लगाएँ?',
      'pictureUnlocked': 'अनलॉक',
      'tapToChangePicture': 'तस्वीर बदलने के लिए टैप करें',
      'rentForDays': '{days} दिन',
      'daysLeft': '{days} दिन बाकी',
      'unlockRentBody': '{name} की कीमत {cost} चिप्स है और यह {days} दिन तक आपका रहेगा। अभी अनलॉक करके लगाएँ?',
      'pictureFree': 'मुफ़्त',
      'picturePremium': 'प्रीमियम',
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
      'fourHourBonus': '৪-ঘণ্টার বোনাস',
      'milestone': 'মাইলস্টোন',
      'collect': 'নিন',
      'rewardCollected': 'পুরস্কার সংগ্রহ হয়েছে!',
      'rewardComeBack': '৪ ঘণ্টা পরে আবার আসুন।',
      'rewardPurchased': 'চিপ আপনার ওয়ালেটে আছে। শুভকামনা।',
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
      'storeBonus': 'বোনাস',
      'storeNotLive': 'পেমেন্ট এখনও চালু নয় — কোনও চার্জ হয়নি।',
      'posStarter': 'শুরু',
      'posPopular': 'জনপ্রিয়',
      'posBestValue': 'সেরা মূল্য',
      'posPremium': 'প্রিমিয়াম',
      'comingSoonBody':
          'চিপ কেনা এখনও চালু হয়নি। ততক্ষণ আপনার পুরস্কার নিতে থাকুন।',
      'handsToGo': 'হাত বাকি',
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
      'serviceUnavailable': 'পরিষেবা উপলব্ধ নেই',
      'soundLabel': 'শব্দ',
      'vibrationLabel': 'কম্পন',
      'useProviderPicture': 'আমার Google/Facebook ছবি ব্যবহার করুন',
      'pictureLocked': 'টেবিলে বসার পর এটি বদলানো যায় না।',
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
      'sideshowRunning': 'সাইডশো',
      'accept': 'গ্রহণ করুন',
      'decline': 'প্রত্যাখ্যান',
      'sideshowDeclined': 'আপনার সাইডশো প্রত্যাখ্যান করা হয়েছে',
      'sideshowTimedOut': 'কোনও উত্তর নেই — সাইডশো বাতিল',
      'sideshowCancelled': 'সাইডশো বাতিল হয়েছে',
      'sideshowYouLost': 'আপনার তাস দুর্বল ছিল — আপনি প্যাক হলেন',
      'sideshowYouWon': 'আপনার তাস ভালো ছিল — তিনি প্যাক হলেন',
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
      'tableLost': 'আপনি দূরে থাকাকালীন টেবিল বন্ধ হয়ে গেছে।',
      'winner': 'বিজয়ী',
      'tableChat': 'টেবিল চ্যাট',
      'saySomething': 'কিছু বলুন…',
      'tableMenu': 'টেবিল মেনু',
      'unlock': 'আনলক করুন',
      'unlockTitle': 'এই ছবিটি আনলক করবেন?',
      'unlockBody': '{name} এর দাম {cost} চিপস। এখনই আনলক করে ব্যবহার করবেন?',
      'pictureUnlocked': 'আনলক',
      'tapToChangePicture': 'ছবি বদলাতে ট্যাপ করুন',
      'rentForDays': '{days} দিন',
      'daysLeft': '{days} দিন বাকি',
      'unlockRentBody': '{name} এর দাম {cost} চিপস এবং এটি {days} দিন আপনার থাকবে। এখনই আনলক করে ব্যবহার করবেন?',
      'pictureFree': 'ফ্রি',
      'picturePremium': 'প্রিমিয়াম',
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
      'milestone': 'માઇલસ્ટોન',
      'collect': 'લો',
      'rewardCollected': 'ઇનામ મળી ગયું!',
      'rewardComeBack': '4 કલાક પછી ફરી આવો.',
      'rewardPurchased': 'ચિપ્સ તમારા વૉલેટમાં છે. શુભકામના.',
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
      'storeBonus': 'બોનસ',
      'storeNotLive': 'પેમેન્ટ હજી ચાલુ નથી — કોઈ ચાર્જ લેવાયો નથી.',
      'posStarter': 'શરૂઆત',
      'posPopular': 'લોકપ્રિય',
      'posBestValue': 'સૌથી સારું',
      'posPremium': 'પ્રીમિયમ',
      'comingSoonBody':
          'ચિપ્સ ખરીદવાનું હજી શરૂ થયું નથી. ત્યાં સુધી તમારાં ઇનામ લેતા રહો.',
      'handsToGo': 'હાથ બાકી',
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
      'serviceUnavailable': 'સેવા ઉપલબ્ધ નથી',
      'soundLabel': 'અવાજ',
      'vibrationLabel': 'કંપન',
      'useProviderPicture': 'મારો Google/Facebook ફોટો વાપરો',
      'pictureLocked': 'ટેબલ પર બેઠા પછી આ બદલી શકાતું નથી.',
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
      'sideshowRunning': 'સાઇડશો',
      'accept': 'સ્વીકારો',
      'decline': 'નકારો',
      'sideshowDeclined': 'તમારો સાઇડશો નકારાયો',
      'sideshowTimedOut': 'જવાબ નથી — સાઇડશો રદ',
      'sideshowCancelled': 'સાઇડશો રદ થયો',
      'sideshowYouLost': 'તમારાં પત્તાં નબળાં હતાં — તમે પૅક થયા',
      'sideshowYouWon': 'તમારાં પત્તાં સારાં હતાં — તે પૅક થયા',
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
      'unlockBody': '{name} ની કિંમત {cost} ચિપ્સ છે. હમણાં અનલૉક કરીને વાપરવો?',
      'pictureUnlocked': 'અનલૉક',
      'tapToChangePicture': 'ફોટો બદલવા ટૅપ કરો',
      'rentForDays': '{days} દિવસ',
      'daysLeft': '{days} દિવસ બાકી',
      'unlockRentBody': '{name} ની કિંમત {cost} ચિપ્સ છે અને તે {days} દિવસ તમારો રહેશે. હમણાં અનલૉક કરીને વાપરવો?',
      'pictureFree': 'મફત',
      'picturePremium': 'પ્રીમિયમ',
      'appVersion': 'એપ આવૃત્તિ',
      'tableLost': 'તમે દૂર હતા ત્યારે ટેબલ બંધ થઈ ગયું.',
      'winner': 'વિજેતા',
      'tableChat': 'ટેબલ ચૅટ',
      'saySomething': 'કંઈક કહો…',
      'tableMenu': 'ટેબલ મેનૂ',
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
      'milestone': 'ਮਾਈਲਸਟੋਨ',
      'collect': 'ਲਓ',
      'rewardCollected': 'ਇਨਾਮ ਮਿਲ ਗਿਆ!',
      'rewardComeBack': '4 ਘੰਟੇ ਬਾਅਦ ਫਿਰ ਆਓ।',
      'rewardPurchased': 'ਚਿੱਪਾਂ ਤੁਹਾਡੇ ਵਾਲਿਟ ਵਿੱਚ ਹਨ। ਸ਼ੁਭਕਾਮਨਾਵਾਂ।',
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
      'storeBonus': 'ਬੋਨਸ',
      'storeNotLive': 'ਭੁਗਤਾਨ ਹਾਲੇ ਚਾਲੂ ਨਹੀਂ — ਕੋਈ ਚਾਰਜ ਨਹੀਂ ਲਿਆ ਗਿਆ।',
      'posStarter': 'ਸ਼ੁਰੂਆਤ',
      'posPopular': 'ਹਰਮਨ ਪਿਆਰਾ',
      'posBestValue': 'ਵਧੀਆ ਮੁੱਲ',
      'posPremium': 'ਪ੍ਰੀਮੀਅਮ',
      'comingSoonBody':
          'ਚਿਪਸ ਖਰੀਦਣਾ ਅਜੇ ਸ਼ੁਰੂ ਨਹੀਂ ਹੋਇਆ। ਉਦੋਂ ਤੱਕ ਆਪਣੇ ਇਨਾਮ ਲੈਂਦੇ ਰਹੋ।',
      'handsToGo': 'ਹੱਥ ਬਾਕੀ',
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
      'serviceUnavailable': 'ਸੇਵਾ ਉਪਲਬਧ ਨਹੀਂ ਹੈ',
      'soundLabel': 'ਆਵਾਜ਼',
      'vibrationLabel': 'ਕੰਪਨ',
      'useProviderPicture': 'ਮੇਰੀ Google/Facebook ਤਸਵੀਰ ਵਰਤੋ',
      'pictureLocked': 'ਟੇਬਲ ਉੱਤੇ ਬੈਠਣ ਤੋਂ ਬਾਅਦ ਇਹ ਬਦਲੀ ਨਹੀਂ ਜਾ ਸਕਦੀ।',
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
      'sideshowRunning': 'ਸਾਈਡਸ਼ੋ',
      'accept': 'ਮੰਨੋ',
      'decline': 'ਨਾਂਹ ਕਰੋ',
      'sideshowDeclined': 'ਤੁਹਾਡਾ ਸਾਈਡਸ਼ੋ ਨਾਂਹ ਕੀਤਾ ਗਿਆ',
      'sideshowTimedOut': 'ਕੋਈ ਜਵਾਬ ਨਹੀਂ — ਸਾਈਡਸ਼ੋ ਰੱਦ',
      'sideshowCancelled': 'ਸਾਈਡਸ਼ੋ ਰੱਦ ਹੋ ਗਿਆ',
      'sideshowYouLost': 'ਤੁਹਾਡੇ ਪੱਤੇ ਕਮਜ਼ੋਰ ਸਨ — ਤੁਸੀਂ ਪੈਕ ਹੋਏ',
      'sideshowYouWon': 'ਤੁਹਾਡੇ ਪੱਤੇ ਵਧੀਆ ਸਨ — ਉਹ ਪੈਕ ਹੋਏ',
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
      'pictureUnlocked': 'ਅਨਲਾਕ',
      'tapToChangePicture': 'ਤਸਵੀਰ ਬਦਲਣ ਲਈ ਟੈਪ ਕਰੋ',
      'rentForDays': '{days} ਦਿਨ',
      'daysLeft': '{days} ਦਿਨ ਬਾਕੀ',
      'unlockRentBody': '{name} ਦੀ ਕੀਮਤ {cost} ਚਿਪਸ ਹੈ ਅਤੇ ਇਹ {days} ਦਿਨ ਤੁਹਾਡੀ ਰਹੇਗੀ। ਹੁਣੇ ਅਨਲਾਕ ਕਰਕੇ ਲਗਾਉਣੀ ਹੈ?',
      'pictureFree': 'ਮੁਫ਼ਤ',
      'picturePremium': 'ਪ੍ਰੀਮੀਅਮ',
      'missedTurnsLabel': 'ਖੁੰਝੀਆਂ ਚਾਲਾਂ',
      'resumingTable': 'ਤੁਹਾਡੇ ਟੇਬਲ ਤੇ ਵਾਪਸ ਜਾ ਰਹੇ ਹਾਂ…',
      'welcomeBack': 'ਵਾਪਸੀ ਤੇ ਸਵਾਗਤ — ਤੁਸੀਂ ਆਪਣੇ ਟੇਬਲ ਤੇ ਵਾਪਸ ਹੋ।',
      'appVersion': 'ਐਪ ਵਰਜਨ',
      'tableLost': 'ਤੁਸੀਂ ਦੂਰ ਸੀ ਤਾਂ ਟੇਬਲ ਬੰਦ ਹੋ ਗਿਆ।',
      'winner': 'ਜੇਤੂ',
      'tableChat': 'ਟੇਬਲ ਚੈਟ',
      'saySomething': 'ਕੁਝ ਕਹੋ…',
      'tableMenu': 'ਟੇਬਲ ਮੀਨੂ',
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
    },
  };
}
