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
  String get guestHint => _('guestHint');

  // --- lobby
  String get boot => _('boot');
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
  String get handsToGo => _('handsToGo');
  String get settings => _('settings');
  String get language => _('language');
  String get switchTheme => _('switchTheme');
  String get signOut => _('signOut');
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
  String get seeCards => _('seeCards');
  String get blindMovesLeft => _('blindMovesLeft');
  String get lastBlindMove => _('lastBlindMove');
  String get inPot => _('inPot');
  String get waiting => _('waiting');
  String get offline => _('offline');
  String get packed => _('packed');
  String get winner => _('winner');
  String get tableChat => _('tableChat');
  String get saySomething => _('saySomething');
  String get tableMenu => _('tableMenu');
  String get yourChips => _('yourChips');
  String get maxPot => _('maxPot');
  String get nightMode => _('nightMode');
  String get dayMode => _('dayMode');
  String get waitingForPlayers => _('waitingForPlayers');
  String get startingGame => _('startingGame');
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

  // --- name and the entry cap
  String get changeName => _('changeName');
  String get save => _('save');
  String get nameSaved => _('nameSaved');
  String get cappedTitle => _('cappedTitle');
  String get cappedBody => _('cappedBody');
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
      'guestHint':
          "Guest play is keyed to this device's id, so your chips are here next time.",
      'boot': 'boot',
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
      'handsToGo': 'hands to go',
      'settings': 'Settings',
      'language': 'Language',
      'switchTheme': 'Switch theme',
      'signOut': 'Sign out',
      'useProviderPicture': 'Use my Google/Facebook picture',
      'pictureLocked': 'It cannot change once you sit at a table.',
      'pot': 'POT',
      'stake': 'stake',
      'yourTurn': 'YOUR TURN',
      'toAct': 'to act',
      'pack': 'Pack',
      'chaal': 'Chaal',
      'show': 'Show',
      'seeCards': 'See cards',
      'blindMovesLeft': 'blind moves left',
      'lastBlindMove': 'last blind move',
      'inPot': 'in pot',
      'waiting': 'waiting',
      'offline': 'offline',
      'packed': 'PACKED',
      'winner': 'Winner',
      'tableChat': 'Table chat',
      'saySomething': 'Say something…',
      'tableMenu': 'Table menu',
      'yourChips': 'Your chips',
      'maxPot': 'Max pot',
      'nightMode': 'Night mode',
      'dayMode': 'Day mode',
      'waitingForPlayers': 'Waiting for players',
      'startingGame': 'Starting game…',
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
      'joinAnother': 'You can join another straight away',
      'rules': 'Rules',
      'rulesTitle': 'Card ranking',
      'rulesBeats': 'Strongest at the top. Every hand beats everything below it.',
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
      'runOrderNote': 'A-K-Q is the highest run, then A-2-3, then K-Q-J down to 4-3-2.',
      'close': 'Close',
      'changeName': 'Change name',
      'save': 'Save',
      'nameSaved': 'Name updated.',
      'cappedTitle': 'Table closed to you',
      'cappedBody': 'Players holding more than {cap} chips cannot join this table.',
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
      'guestHint':
          'मेहमान खाता इस डिवाइस से जुड़ा है, इसलिए आपके चिप्स अगली बार भी यहीं रहेंगे।',
      'boot': 'बूट',
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
      'handsToGo': 'हाथ बाकी',
      'settings': 'सेटिंग्स',
      'language': 'भाषा',
      'switchTheme': 'थीम बदलें',
      'signOut': 'साइन आउट',
      'useProviderPicture': 'मेरी Google/Facebook तस्वीर लगाएँ',
      'pictureLocked': 'टेबल पर बैठने के बाद इसे बदला नहीं जा सकता।',
      'pot': 'पॉट',
      'stake': 'दांव',
      'yourTurn': 'आपकी बारी',
      'toAct': 'की बारी',
      'pack': 'पैक',
      'chaal': 'चाल',
      'show': 'शो',
      'seeCards': 'पत्ते देखें',
      'blindMovesLeft': 'ब्लाइंड चालें बाकी',
      'lastBlindMove': 'आख़िरी ब्लाइंड चाल',
      'inPot': 'पॉट में',
      'waiting': 'इंतज़ार',
      'offline': 'ऑफ़लाइन',
      'packed': 'पैक',
      'winner': 'विजेता',
      'tableChat': 'टेबल चैट',
      'saySomething': 'कुछ कहें…',
      'tableMenu': 'टेबल मेनू',
      'yourChips': 'आपके चिप्स',
      'maxPot': 'अधिकतम पॉट',
      'nightMode': 'रात मोड',
      'dayMode': 'दिन मोड',
      'waitingForPlayers': 'खिलाड़ियों का इंतज़ार',
      'startingGame': 'खेल शुरू हो रहा है…',
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
      'cappedBody': '{cap} से ज़्यादा चिप्स रखने वाले खिलाड़ी इस टेबल पर नहीं बैठ सकते।',
      'useSocialPicture': 'मेरी Google या Facebook तस्वीर लगाएँ',
      'guestNoSocial': 'अपनी तस्वीर लगाने के लिए Google या Facebook से साइन इन करें।',
    },
    'bn': {
      'signInSubtitle': 'খেলতে সাইন ইন করুন।',
      'displayName': 'নাম',
      'playerHint': 'খেলোয়াড়',
      'playAsGuest': 'অতিথি হিসেবে খেলুন',
      'signingIn': 'সাইন ইন হচ্ছে…',
      'continueGoogle': 'Google দিয়ে চালিয়ে যান',
      'continueFacebook': 'Facebook দিয়ে চালিয়ে যান',
      'guestHint':
          'অতিথি অ্যাকাউন্ট এই ডিভাইসের সঙ্গে যুক্ত, তাই আপনার চিপ পরের বারও থাকবে।',
      'boot': 'বুট',
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
      'handsToGo': 'হাত বাকি',
      'settings': 'সেটিংস',
      'language': 'ভাষা',
      'switchTheme': 'থিম বদলান',
      'signOut': 'সাইন আউট',
      'useProviderPicture': 'আমার Google/Facebook ছবি ব্যবহার করুন',
      'pictureLocked': 'টেবিলে বসার পর এটি বদলানো যায় না।',
      'pot': 'পট',
      'stake': 'বাজি',
      'yourTurn': 'আপনার পালা',
      'toAct': 'এর পালা',
      'pack': 'প্যাক',
      'chaal': 'চাল',
      'show': 'শো',
      'seeCards': 'তাস দেখুন',
      'blindMovesLeft': 'ব্লাইন্ড চাল বাকি',
      'lastBlindMove': 'শেষ ব্লাইন্ড চাল',
      'inPot': 'পটে',
      'waiting': 'অপেক্ষা',
      'offline': 'অফলাইন',
      'packed': 'প্যাক',
      'winner': 'বিজয়ী',
      'tableChat': 'টেবিল চ্যাট',
      'saySomething': 'কিছু বলুন…',
      'tableMenu': 'টেবিল মেনু',
      'yourChips': 'আপনার চিপ',
      'maxPot': 'সর্বোচ্চ পট',
      'nightMode': 'রাত মোড',
      'dayMode': 'দিন মোড',
      'waitingForPlayers': 'খেলোয়াড়ের অপেক্ষা',
      'startingGame': 'খেলা শুরু হচ্ছে…',
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
      'joinAnother': 'আপনি সঙ্গে সঙ্গে অন্য টেবিলে যোগ দিতে পারেন',
      'rules': 'নিয়ম',
      'rulesTitle': 'তাসের র‍্যাঙ্কিং',
      'rulesBeats': 'উপরেরটি সবচেয়ে শক্তিশালী। প্রতিটি হাত নিচের সবগুলিকে হারায়।',
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
      'runOrderNote': 'A-K-Q সবচেয়ে উঁচু, তারপর A-2-3, তারপর K-Q-J থেকে 4-3-2 পর্যন্ত।',
      'close': 'বন্ধ করুন',
      'changeName': 'নাম বদলান',
      'save': 'সেভ করুন',
      'nameSaved': 'নাম বদলে গেছে।',
      'cappedTitle': 'এই টেবিল আপনার জন্য বন্ধ',
      'cappedBody': '{cap} এর বেশি চিপ থাকা খেলোয়াড়েরা এই টেবিলে বসতে পারেন না।',
      'useSocialPicture': 'আমার Google বা Facebook ছবি ব্যবহার করুন',
      'guestNoSocial': 'নিজের ছবি ব্যবহার করতে Google বা Facebook দিয়ে সাইন ইন করুন।',
    },
    'gu': {
      'signInSubtitle': 'રમવા માટે સાઇન ઇન કરો.',
      'displayName': 'નામ',
      'playerHint': 'ખેલાડી',
      'playAsGuest': 'મહેમાન તરીકે રમો',
      'signingIn': 'સાઇન ઇન થઈ રહ્યું છે…',
      'continueGoogle': 'Google થી ચાલુ રાખો',
      'continueFacebook': 'Facebook થી ચાલુ રાખો',
      'guestHint':
          'મહેમાન ખાતું આ ડિવાઇસ સાથે જોડાયેલું છે, તેથી તમારા ચિપ્સ આવતી વખતે પણ અહીં જ રહેશે.',
      'boot': 'બૂટ',
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
      'handsToGo': 'હાથ બાકી',
      'settings': 'સેટિંગ્સ',
      'language': 'ભાષા',
      'switchTheme': 'થીમ બદલો',
      'signOut': 'સાઇન આઉટ',
      'useProviderPicture': 'મારો Google/Facebook ફોટો વાપરો',
      'pictureLocked': 'ટેબલ પર બેઠા પછી આ બદલી શકાતું નથી.',
      'pot': 'પોટ',
      'stake': 'દાવ',
      'yourTurn': 'તમારો વારો',
      'toAct': 'નો વારો',
      'pack': 'પૅક',
      'chaal': 'ચાલ',
      'show': 'શો',
      'seeCards': 'પત્તા જુઓ',
      'blindMovesLeft': 'બ્લાઇન્ડ ચાલ બાકી',
      'lastBlindMove': 'છેલ્લી બ્લાઇન્ડ ચાલ',
      'inPot': 'પોટમાં',
      'waiting': 'રાહ',
      'offline': 'ઑફલાઇન',
      'packed': 'પૅક',
      'winner': 'વિજેતા',
      'tableChat': 'ટેબલ ચૅટ',
      'saySomething': 'કંઈક કહો…',
      'tableMenu': 'ટેબલ મેનૂ',
      'yourChips': 'તમારા ચિપ્સ',
      'maxPot': 'મહત્તમ પોટ',
      'nightMode': 'રાત મોડ',
      'dayMode': 'દિવસ મોડ',
      'waitingForPlayers': 'ખેલાડીઓની રાહ',
      'startingGame': 'રમત શરૂ થાય છે…',
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
      'quitGameBody': 'તમે ગમે ત્યારે પાછા આવી શકો છો — તમારા ચિપ્સ સચવાયેલા છે.',
      'quit': 'બંધ કરો',
      'cancel': 'રદ કરો',
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
      'cappedBody': '{cap} થી વધુ ચિપ્સ ધરાવતા ખેલાડીઓ આ ટેબલ પર બેસી શકતા નથી.',
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
      'guestHint':
          'ਮਹਿਮਾਨ ਖਾਤਾ ਇਸ ਡਿਵਾਈਸ ਨਾਲ ਜੁੜਿਆ ਹੈ, ਇਸ ਲਈ ਤੁਹਾਡੇ ਚਿਪਸ ਅਗਲੀ ਵਾਰ ਵੀ ਇੱਥੇ ਹੋਣਗੇ।',
      'boot': 'ਬੂਟ',
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
      'handsToGo': 'ਹੱਥ ਬਾਕੀ',
      'settings': 'ਸੈਟਿੰਗਾਂ',
      'language': 'ਭਾਸ਼ਾ',
      'switchTheme': 'ਥੀਮ ਬਦਲੋ',
      'signOut': 'ਸਾਈਨ ਆਊਟ',
      'useProviderPicture': 'ਮੇਰੀ Google/Facebook ਤਸਵੀਰ ਵਰਤੋ',
      'pictureLocked': 'ਟੇਬਲ ਉੱਤੇ ਬੈਠਣ ਤੋਂ ਬਾਅਦ ਇਹ ਬਦਲੀ ਨਹੀਂ ਜਾ ਸਕਦੀ।',
      'pot': 'ਪੌਟ',
      'stake': 'ਦਾਅ',
      'yourTurn': 'ਤੁਹਾਡੀ ਵਾਰੀ',
      'toAct': 'ਦੀ ਵਾਰੀ',
      'pack': 'ਪੈਕ',
      'chaal': 'ਚਾਲ',
      'show': 'ਸ਼ੋ',
      'seeCards': 'ਪੱਤੇ ਵੇਖੋ',
      'blindMovesLeft': 'ਬਲਾਈਂਡ ਚਾਲਾਂ ਬਾਕੀ',
      'lastBlindMove': 'ਆਖ਼ਰੀ ਬਲਾਈਂਡ ਚਾਲ',
      'inPot': 'ਪੌਟ ਵਿੱਚ',
      'waiting': 'ਉਡੀਕ',
      'offline': 'ਔਫ਼ਲਾਈਨ',
      'packed': 'ਪੈਕ',
      'winner': 'ਜੇਤੂ',
      'tableChat': 'ਟੇਬਲ ਚੈਟ',
      'saySomething': 'ਕੁਝ ਕਹੋ…',
      'tableMenu': 'ਟੇਬਲ ਮੀਨੂ',
      'yourChips': 'ਤੁਹਾਡੇ ਚਿਪਸ',
      'maxPot': 'ਵੱਧ ਤੋਂ ਵੱਧ ਪੌਟ',
      'nightMode': 'ਰਾਤ ਮੋਡ',
      'dayMode': 'ਦਿਨ ਮੋਡ',
      'waitingForPlayers': 'ਖਿਡਾਰੀਆਂ ਦੀ ਉਡੀਕ',
      'startingGame': 'ਖੇਡ ਸ਼ੁਰੂ ਹੋ ਰਹੀ ਹੈ…',
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
      'joinAnother': 'ਤੁਸੀਂ ਤੁਰੰਤ ਕਿਸੇ ਹੋਰ ਟੇਬਲ ਉੱਤੇ ਜੁੜ ਸਕਦੇ ਹੋ',
      'rules': 'ਨਿਯਮ',
      'rulesTitle': 'ਪੱਤਿਆਂ ਦੀ ਰੈਂਕਿੰਗ',
      'rulesBeats': 'ਉੱਪਰ ਵਾਲਾ ਸਭ ਤੋਂ ਤਕੜਾ। ਹਰ ਹੱਥ ਹੇਠਲੇ ਸਾਰਿਆਂ ਨੂੰ ਹਰਾਉਂਦਾ ਹੈ।',
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
      'cappedBody': '{cap} ਤੋਂ ਵੱਧ ਚਿਪਸ ਰੱਖਣ ਵਾਲੇ ਖਿਡਾਰੀ ਇਸ ਟੇਬਲ ਉੱਤੇ ਨਹੀਂ ਬੈਠ ਸਕਦੇ।',
      'useSocialPicture': 'ਮੇਰੀ Google ਜਾਂ Facebook ਤਸਵੀਰ ਵਰਤੋ',
      'guestNoSocial': 'ਆਪਣੀ ਤਸਵੀਰ ਵਰਤਣ ਲਈ Google ਜਾਂ Facebook ਨਾਲ ਸਾਈਨ ਇਨ ਕਰੋ।',
    },
  };
}
