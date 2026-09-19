// The words the poker family brought with it.
//
// A missing translation does not show as a key: `Strings` falls back to the
// English. So "written in every language" is checked against each language's
// own entry, not against what the getter happens to return.
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';

/// Every new key, with the placeholders its text must keep.
const _newKeys = <String, List<String>>{
  'poker': [],
  'pokerTableNote': [],
  'pokerTexasHoldem': [],
  'pokerOmaha': [],
  'pokerFiveCardDraw': [],
  'pokerThreeCardPoker': [],
  'pokerTexasHoldemNote': [],
  'pokerOmahaNote': [],
  'pokerFiveCardDrawNote': [],
  'pokerThreeCardPokerNote': [],
  'blindsLabel': [],
  'anteLabel': [],
  'blindsTitle': [],
  'anteTitle': [],
  'buyInLabel': [],
  'holeCardsLabel': [],
  'maxDiscardsLabel': [],
  'buyInFrom': ['{min}'],
  'fold': [],
  'check': [],
  'call': [],
  'bet': [],
  'raise': [],
  'allIn': [],
  'play': [],
  'draw': [],
  'standPat': [],
  'exchangeUpTo': ['{n}'],
  'playOrFold': [],
  'dealerLabel': [],
  'dealerQualifies': [],
  'dealerNotQualified': [],
  'youWon': ['{amount}'],
  'youLost': [],
  'outcomeWin': [],
  'outcomeLose': [],
  'push': [],
  'potLabel': [],
  'sidePotLabel': [],
  'boardLabel': [],
  'streetPreflop': [],
  'streetFlop': [],
  'streetTurn': [],
  'streetRiver': [],
  'streetPredraw': [],
  'streetDraw': [],
  'streetPostdraw': [],
  'streetDecision': [],
  'streetShowdown': [],
  'pokerTimedOut': [],
  'pokerRulesTitle': [],
  'pokerRulesIntro': [],
  'pokerRankRoyalFlush': [],
  'pokerRankStraightFlush': [],
  'pokerRankFourOfAKind': [],
  'pokerRankFullHouse': [],
  'pokerRankFlush': [],
  'pokerRankStraight': [],
  'pokerRankThreeOfAKind': [],
  'pokerRankTwoPair': [],
  'pokerRankPair': [],
  'pokerRankHighCard': [],
  'pokerThreeCardRanking': [],
  'rulePokerBlinds': ['{small}', '{big}'],
  'rulePokerAnte': ['{ante}'],
  'rulePokerBuyIn': ['{min}'],
  'rulePokerHoleCards': ['{n}'],
  'rulePokerHoldemWin': [],
  'rulePokerOmahaWin': [],
  'rulePokerDrawWin': ['{n}'],
  'rulePokerThreeCardWin': [],
  'rulePokerDealerQualifies': [],
  'rulePokerBestHandWins': [],
  'refuseNotYourTurn': [],
  'refuseInvalidAction': [],
  'refuseInvalidAmount': [],
  'refuseInvalidDiscard': [],
  'refuseInsufficientChips': [],
  'refuseNoHand': [],
  'refuseNotInHand': [],
  'refuseWrongGame': [],
  'refuseDuplicateAction': [],
  'refuseUnknownAction': [],
};

const _rankKeys = [
  'royalFlush',
  'straightFlush',
  'fourOfAKind',
  'fullHouse',
  'flush',
  'straight',
  'threeOfAKind',
  'twoPair',
  'pair',
  'highCard',
];

const _refusalCodes = [
  'not_your_turn',
  'invalid_action',
  'invalid_amount',
  'invalid_discard',
  'insufficient_chips',
  'no_hand',
  'not_in_hand',
  'wrong_game',
  'duplicate_action',
  'unknown_action',
];

void main() {
  for (final lang in AppLang.values) {
    test('every poker word is written in ${lang.englishName}', () {
      final t = Strings(lang);
      const english = Strings(AppLang.english);
      for (final MapEntry(key: key, value: placeholders) in _newKeys.entries) {
        final own = t.ownEntry(key);
        expect(own, isNotNull, reason: '${lang.code} has no "$key"');
        expect(own!.trim(), isNotEmpty, reason: '${lang.code} "$key"');
        for (final placeholder in placeholders) {
          expect(
            own,
            contains(placeholder),
            reason: '${lang.code} "$key" lost $placeholder',
          );
        }
        if (lang != AppLang.english) {
          expect(
            own,
            isNot(english.ownEntry(key)),
            reason: '${lang.code} "$key" is still the English',
          );
        }
      }
    });

    test('${lang.englishName} names every game, street, rank and refusal', () {
      final t = Strings(lang);
      for (final wire in TableCategory.pokerCategories) {
        expect(t.pokerVariantName(wire), isNot(wire), reason: wire);
        expect(t.pokerVariantNote(wire), isNotEmpty, reason: wire);
        expect(t.variationOrCategory(wire), t.pokerVariantName(wire));
      }
      expect(t.variationOrCategory(TableCategory.pokerFamily), t.poker);
      for (final street in const [
        PokerStreet.preflop,
        PokerStreet.flop,
        PokerStreet.turn,
        PokerStreet.river,
        PokerStreet.predraw,
        PokerStreet.draw,
        PokerStreet.postdraw,
        PokerStreet.decision,
        PokerStreet.showdown,
      ]) {
        expect(t.pokerStreetName(street), isNot(street), reason: street);
      }
      for (final rank in _rankKeys) {
        expect(t.pokerRankName(rank), isNot(rank), reason: rank);
      }
      for (final code in _refusalCodes) {
        expect(t.pokerRefusal(code), isNotNull, reason: code);
      }
      for (final outcome in const ['win', 'lose', 'push']) {
        expect(t.pokerOutcome(outcome), isNotEmpty, reason: outcome);
      }
    });
  }

  test('the English says what the owner asked for', () {
    const t = Strings(AppLang.english);
    expect(t.poker, 'POKER');
    expect(t.pokerVariantName('texas_holdem'), "Texas Hold'em");
    expect(t.pokerVariantName('omaha'), 'Omaha');
    expect(t.pokerVariantName('five_card_draw'), '5-Card Draw');
    expect(t.pokerVariantName('three_card_poker'), '3-Card Poker');
    expect(t.exchangeUpTo(3), 'Choose up to 3 cards to exchange');
    expect(t.playOrFold, 'Play or fold?');
    expect(t.buyInFrom('2,000'), 'from 2,000');
    expect(t.rulePokerBlinds('100', '200'), 'Blinds of 100 and 200 start every hand');
    expect(t.blindsTitle, 'Blinds');
    expect(t.anteTitle, 'Ante');
  });

  test('what this build does not know is shown as sent, or kept', () {
    const t = Strings(AppLang.hindi);
    expect(t.pokerVariantName('razz'), 'razz');
    expect(t.pokerVariantNote('razz'), isEmpty);
    expect(t.pokerStreetName('fourth'), 'fourth');
    expect(t.pokerStreetName(''), '');
    expect(t.pokerRefusal('no_such_code'), isNull);
    expect(t.pokerRefusal(null), isNull);
    expect(t.pokerOutcome(null), isEmpty);
  });
}
