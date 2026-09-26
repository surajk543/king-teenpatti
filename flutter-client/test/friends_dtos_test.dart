// Friends V1 on the wire (owner, 26 Sep 2026): the readers of every answer
// the contract names, tolerant as every DTO in the app; the friend list's
// order; the game a playing friend is at, in the app's own names; and every
// word the feature says, in all five languages — every refusal code included.
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/friends.dart';
import 'package:teenpatti/screens/friends_screen.dart';
import 'package:teenpatti/state/friends_state.dart';

import 'friends_fixture.dart';

void main() {
  group('a player card', () {
    test('reads the id, the name and the picture', () {
      final card = PlayerCard.fromJson({
        'userId': 'u1',
        'displayName': 'Ravi',
        'profilePicture': {'id': 7, 'url': '/profiles/tiger.svg'},
      });
      expect(card.userId, 'u1');
      expect(card.displayName, 'Ravi');
      expect(card.pictureId, 7);
      expect(card.pictureUrl, '/profiles/tiger.svg');
    });

    test('a player wearing nothing has no picture, never an id of 0', () {
      final card = PlayerCard.fromJson(cardJson('u1', 'Ravi'));
      expect(card.pictureId, isNull);
      expect(card.pictureUrl, isNull);
      final junk = PlayerCard.fromJson({
        'userId': 5,
        'displayName': null,
        'profilePicture': 'x',
      });
      expect(junk.userId, '');
      expect(junk.displayName, '');
      expect(junk.pictureUrl, isNull);
    });
  });

  group('a friend', () {
    test('playing: status, both flags, the game and the variant', () {
      final f = FriendItem.fromJson(
        friendJson(
          'u1',
          'Meera',
          status: 'PLAYING',
          game: 'TEEN_PATTI',
          variant: 'SEEN',
          since: 99,
        ),
      );
      expect(f.userId, 'u1');
      expect(f.displayName, 'Meera');
      expect(f.presence.status, PresenceStatus.playing);
      expect(f.presence.isPlaying, isTrue);
      expect(f.presence.isOnline, isTrue);
      expect(f.presence.online, isTrue);
      expect(f.presence.game, 'TEEN_PATTI');
      expect(f.presence.variant, 'SEEN');
      expect(f.friendsSince, 99);
    });

    test('online and offline carry no game', () {
      final online = FriendItem.fromJson({
        ...friendJson('u1', 'A', status: 'ONLINE'),
        'game': 'POKER',
        'variant': 'OMAHA',
      });
      expect(online.presence.isOnline, isTrue);
      expect(online.presence.isPlaying, isFalse);
      expect(online.presence.game, isNull);
      expect(online.presence.variant, isNull);
      final offline = FriendItem.fromJson(friendJson('u2', 'B'));
      expect(offline.presence.status, PresenceStatus.offline);
      expect(offline.presence.isOnline, isFalse);
    });

    test('a status this build does not know is worked out from the flags', () {
      FriendPresence read(Map<String, dynamic> j) => FriendPresence.fromJson(j);
      expect(
        read({'status': 'AWAY', 'online': true, 'playing': true}).status,
        PresenceStatus.playing,
      );
      expect(read({'status': 7, 'online': true}).status, PresenceStatus.online);
      expect(read(const {}).status, PresenceStatus.offline);
    });

    test('the list is PLAYING, then ONLINE, then OFFLINE, by name', () {
      final sorted = sortFriends([
        FriendItem.fromJson(friendJson('1', 'zed')),
        FriendItem.fromJson(friendJson('2', 'Amy')),
        FriendItem.fromJson(friendJson('3', 'bob', status: 'ONLINE')),
        FriendItem.fromJson(friendJson('4', 'Ann', status: 'ONLINE')),
        FriendItem.fromJson(
          friendJson('5', 'yan', status: 'PLAYING', game: 'POKER'),
        ),
        FriendItem.fromJson(
          friendJson('6', 'Carl', status: 'PLAYING', game: 'TEEN_PATTI'),
        ),
      ]);
      expect(sorted.map((f) => f.displayName), [
        'Carl',
        'yan',
        'Ann',
        'bob',
        'Amy',
        'zed',
      ]);
    });
  });

  group('the requests', () {
    test('both ways, with their ids, numbers or text', () {
      final r = FriendRequests.fromJson({
        'incoming': [
          requestJson(41, 'u-ravi', 'Ravi'),
          {'requestId': '42', 'player': cardJson('u-isha', 'Isha')},
          // No id: neither accepted nor rejected, so not shown.
          {'player': cardJson('u-x', 'X')},
          'junk',
        ],
        'outgoing': [requestJson(43, 'u-dev', 'Dev')],
      });
      expect(r.incoming.map((e) => e.requestId), ['41', '42']);
      expect(r.incoming.first.player.displayName, 'Ravi');
      expect(r.incoming.first.createdAt, greaterThan(0));
      expect(r.outgoing.single.requestId, '43');
      expect(FriendRequests.fromJson(const {}).incoming, isEmpty);
    });

    test('a request id is text whichever way it comes, and never a 0', () {
      expect(friendRequestIdOf(41), '41');
      expect(friendRequestIdOf(41.0), '41');
      expect(friendRequestIdOf(' 42 '), '42');
      expect(friendRequestIdOf(null), isNull);
      expect(friendRequestIdOf(''), isNull);
      expect(friendRequestIdOf(true), isNull);
    });
  });

  group('a lookup', () {
    test('carries the request id only while a request is pending', () {
      for (final status in ['PENDING_SENT', 'PENDING_RECEIVED']) {
        final l = PlayerLookup.fromJson({
          'player': cardJson('u1', 'Ravi'),
          'friendStatus': status,
          'requestId': 41,
        });
        expect(l.friendStatus, status);
        expect(l.requestId, '41');
      }
      for (final status in ['NONE', 'FRIENDS', 'SELF']) {
        final l = PlayerLookup.fromJson({
          'player': cardJson('u1', 'Ravi'),
          'friendStatus': status,
          'requestId': 41,
        });
        expect(l.friendStatus, status);
        expect(l.requestId, isNull, reason: status);
      }
    });

    test('a status this build does not know offers Add Friend again', () {
      final l = PlayerLookup.fromJson({
        'player': cardJson('u1', 'Ravi'),
        'friendStatus': 'BLOCKED',
      });
      expect(l.friendStatus, FriendStatus.none);
    });
  });

  group('a profile', () {
    test('a friend\'s carries where they are, and the record', () {
      final p = PublicProfile.fromJson({
        'profile': {
          ...cardJson('u1', 'Meera'),
          'friendStatus': 'FRIENDS',
          'presence': {
            'status': 'PLAYING',
            'online': true,
            'playing': true,
            'game': 'POKER',
            'variant': 'TEXAS_HOLDEM',
          },
          'stats': statsJson(),
        },
      });
      expect(p.userId, 'u1');
      expect(p.friendStatus, FriendStatus.friends);
      expect(p.presence?.isPlaying, isTrue);
      expect(p.presence?.variant, 'TEXAS_HOLDEM');
      expect(p.stats.handsPlayed, 120);
      expect(p.stats.handsWon, 61);
      expect(p.stats.handsLost, 52);
      expect(p.stats.handsLeft, 7);
      expect(p.stats.winRate, 50.83);
    });

    test('anybody else\'s carries no presence at all', () {
      final p = PublicProfile.fromJson({
        'profile': {
          ...cardJson('u1', 'Ravi'),
          'friendStatus': 'PENDING_RECEIVED',
          'requestId': 41,
          'stats': statsJson(played: 0, winRate: 0),
        },
      });
      expect(p.presence, isNull);
      expect(p.requestId, '41');
    });

    test('a record out of range is held to 0..100, and junk reads as 0', () {
      expect(PlayerStats.fromJson({'winRate': 250}).winRate, 100);
      expect(PlayerStats.fromJson({'winRate': -3}).winRate, 0);
      final junk = PlayerStats.fromJson({
        'handsPlayed': 'many',
        'winRate': 'high',
      });
      expect(junk.handsPlayed, 0);
      expect(junk.winRate, 0);
      expect(PublicProfile.fromJson(const {}).stats.handsPlayed, 0);
    });

    test('ending a friendship takes where they are with it', () {
      final p = PublicProfile.fromJson({
        'profile': {
          ...cardJson('u1', 'Meera'),
          'friendStatus': 'FRIENDS',
          'presence': {'status': 'ONLINE', 'online': true},
          'stats': statsJson(),
        },
      });
      final gone = p.withStatus(FriendStatus.none);
      expect(gone.friendStatus, FriendStatus.none);
      expect(gone.presence, isNull);
      expect(gone.stats.handsPlayed, 120);
    });
  });

  group('the game a playing friend is at', () {
    FriendPresence playing(String game, String variant) => FriendPresence(
      status: PresenceStatus.playing,
      online: true,
      playing: true,
      game: game,
      variant: variant,
    );

    test('is the app\'s own names, as names', () {
      const t = Strings(AppLang.english);
      expect(
        presenceGameLine(t, playing('TEEN_PATTI', 'SEEN')),
        'Teen Patti • Seen',
      );
      expect(
        presenceGameLine(t, playing('TEEN_PATTI', 'BLIND')),
        'Teen Patti • Blind',
      );
      expect(
        presenceGameLine(t, playing('TEEN_PATTI', 'VARIATION')),
        'Teen Patti • Variation',
      );
      expect(
        presenceGameLine(t, playing('POKER', 'TEXAS_HOLDEM')),
        "Poker • Texas Hold'em",
      );
      expect(presenceGameLine(t, playing('POKER', 'OMAHA')), 'Poker • Omaha');
      expect(
        presenceGameLine(t, playing('POKER', 'FIVE_CARD_DRAW')),
        'Poker • 5-Card Draw',
      );
      expect(
        presenceGameLine(t, playing('POKER', 'THREE_CARD_POKER')),
        'Poker • 3-Card Poker',
      );
    });

    test('in each language, from that language\'s names', () {
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        final line = presenceGameLine(t, playing('POKER', 'TEXAS_HOLDEM'))!;
        expect(line, contains(t.pokerVariantName('texas_holdem')));
        final tp = presenceGameLine(t, playing('TEEN_PATTI', 'SEEN'))!;
        expect(tp, contains(friendlyName(t.seen)));
        expect(tp, contains(friendlyName(t.teenPatti)));
      }
      expect(
        presenceGameLine(
          const Strings(AppLang.hindi),
          playing('TEEN_PATTI', 'BLIND'),
        ),
        'तीन पत्ती • ब्लाइंड',
      );
    });

    test('a game this build does not know goes by the server\'s name', () {
      const t = Strings(AppLang.english);
      expect(
        presenceGameLine(
          t,
          playing('RUMMY', 'POINTS_RUMMY'),
          engineName: (e) => e == 'rummy' ? 'Rummy' : null,
          categoryName: (c) => c == 'points_rummy' ? 'Points' : null,
        ),
        'Rummy • Points',
      );
      expect(
        presenceGameLine(t, playing('RUMMY', 'POINTS_RUMMY')),
        'Rummy • Points Rummy',
      );
    });

    test('is nothing while they are not playing', () {
      const t = Strings(AppLang.english);
      expect(presenceGameLine(t, FriendPresence.offline), isNull);
      expect(
        presenceGameLine(
          t,
          const FriendPresence(status: PresenceStatus.online, online: true),
        ),
        isNull,
      );
    });

    test('names in capitals become names; other scripts are left alone', () {
      expect(friendlyName('TEEN PATTI'), 'Teen Patti');
      expect(friendlyName('SEEN'), 'Seen');
      expect(friendlyName("Texas Hold'em"), "Texas Hold'em");
      expect(friendlyName('5-Card Draw'), '5-Card Draw');
      expect(friendlyName('सीन'), 'सीन');
    });
  });

  group('the words', () {
    const keys = [
      'friends',
      'friendRequestWaiting',
      'friendRequestsWaiting',
      'yourPlayerId',
      'copyId',
      'idCopied',
      'addFriend',
      'friendRequests',
      'noFriendRequests',
      'noFriendsTitle',
      'noFriendsBody',
      'friendsLoadFailed',
      'friendsRetry',
      'friendAccept',
      'friendReject',
      'wantsToBeFriends',
      'presenceOnline',
      'presenceOffline',
      'playingNow',
      'addFriendHint',
      'addFriendHowTo',
      'playerIdLabel',
      'searchPlayer',
      'requestSent',
      'thatsYou',
      'enterPlayerId',
      'playerProfile',
      'winRate',
      'removeFriend',
      'removeFriendQ',
      'removeFriendBody',
      'removeFriendConfirm',
      'profileLoadFailed',
      'back',
      'friendAdded',
      'friendRemoved',
      'friendRefusePlayerNotFound',
      'friendRefuseInvalidId',
      'friendRefuseSelf',
      'friendRefuseAlreadyFriends',
      'friendRefuseAlreadySent',
      'friendRefuseAlreadyReceived',
      'friendRefuseRequestGone',
      'friendRefuseNotPending',
      'friendRefuseNotFriends',
      'friendRefuseRateLimited',
      'friendActionFailed',
    ];

    test('every Friends word is in all five languages', () {
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        for (final key in keys) {
          expect(t.ownEntry(key), isNotNull, reason: '${lang.name} $key');
          expect(t.ownEntry(key), isNotEmpty, reason: '${lang.name} $key');
        }
        expect(t.removeFriendQ('Ravi'), contains('Ravi'));
        expect(t.friendAdded('Ravi'), contains('Ravi'));
        expect(t.friendRemoved('Ravi'), contains('Ravi'));
        expect(t.friendRequestsWaiting(3), contains('3'));
        expect(t.friendRequestsWaiting(1), contains('1'));
        if (lang != AppLang.english) {
          // Translated, not the English falling through.
          expect(t.addFriend, isNot('Add Friend'), reason: lang.name);
          expect(t.playingNow, isNot('Playing now'), reason: lang.name);
        }
      }
    });

    test('every refusal the contract names is said in words of its own', () {
      const codes = {
        'player_not_found': 'friendRefusePlayerNotFound',
        'invalid_player_id': 'friendRefuseInvalidId',
        'self_request': 'friendRefuseSelf',
        'already_friends': 'friendRefuseAlreadyFriends',
        'request_already_sent': 'friendRefuseAlreadySent',
        'request_already_received': 'friendRefuseAlreadyReceived',
        'request_not_found': 'friendRefuseRequestGone',
        'request_not_pending': 'friendRefuseNotPending',
        'not_friends': 'friendRefuseNotFriends',
        'rate_limited': 'friendRefuseRateLimited',
      };
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        final said = <String>{};
        for (final MapEntry(key: code, value: key) in codes.entries) {
          final text = friendsRefusalText(t, code);
          expect(text, t.ownEntry(key), reason: '${lang.name} $code');
          said.add(text);
        }
        // Ten codes, ten sentences.
        expect(said, hasLength(codes.length), reason: lang.name);
        expect(friendsRefusalText(t, friendsNoAnswer), t.notConnected);
        expect(friendsRefusalText(t, friendsEmptyId), t.enterPlayerId);
        expect(friendsRefusalText(t, 'brand_new'), t.friendActionFailed);
        expect(friendsRefusalText(t, null), t.friendActionFailed);
      }
      expect(
        friendsRefusalText(const Strings(AppLang.english), 'player_not_found'),
        'Player not found.',
      );
    });
  });
}
