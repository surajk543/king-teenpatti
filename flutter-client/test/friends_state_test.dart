// Friends V1's state on the phone (owner, 26 Sep 2026): what the app does with
// each answer — a request sent stands as PENDING_SENT, an accept moves the
// request into the friend list in its place, a reject and a removal take the
// row away at once, the lobby key counts the requests waiting — and when it
// asks: the lists every fifteen seconds while the page is open and never once
// it closes, the count every minute while the lobby shows.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/friends.dart';
import 'package:teenpatti/state/friends_state.dart';

import 'friends_fixture.dart';

Future<T> _on<T>(FakeFriendsServer server, Future<T> Function() body) =>
    http.runWithClient(body, () => server.client);

void main() {
  group('the lobby key\'s count', () {
    test('is the requests waiting for the player', () async {
      final server = populatedServer();
      final state = signedInState();
      await _on(server, () => state.friends.refreshBadge());
      expect(state.friends.incomingCount, 2);
      expect(state.friends.incoming.map((r) => r.requestId), ['41', '42']);
      expect(state.friends.available, isTrue);
      expect(server.count('GET', '/api/friends/requests'), 1);
      expect(server.count('GET', '/api/friends'), 0);
      state.dispose();
    });

    test('a server from before Friends puts the key away', () async {
      final server = FakeFriendsServer()..unsupported = true;
      final state = signedInState();
      await _on(server, () => state.friends.refreshBadge());
      expect(state.friends.available, isFalse);
      server.unsupported = false;
      await _on(server, () => state.friends.refreshBadge());
      expect(state.friends.available, isTrue);
      state.dispose();
    });

    test('is never asked for without a session', () async {
      final server = populatedServer();
      final state = signedInState()..debugToken = null;
      await _on(server, () => state.friends.refreshBadge());
      await _on(server, () => state.friends.refresh());
      expect(server.sent, isEmpty);
      state.dispose();
    });
  });

  group('when the app asks', () {
    testWidgets('the page reads both lists as it opens, every 15 s while it '
        'is open, and never once it has closed', (tester) async {
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        final friends = state.friends;
        friends.pageOpened();
        await tester.pump();
        expect(server.count('GET', '/api/friends'), 1);
        expect(server.count('GET', '/api/friends/requests'), 1);
        expect(friends.loaded, isTrue);
        expect(friends.friends, hasLength(3));

        await tester.pump(const Duration(seconds: 14));
        expect(server.count('GET', '/api/friends'), 1);
        await tester.pump(const Duration(seconds: 1));
        expect(server.count('GET', '/api/friends'), 2);
        await tester.pump(const Duration(seconds: 15));
        expect(server.count('GET', '/api/friends'), 3);
        expect(server.count('GET', '/api/friends/requests'), 3);

        friends.pageClosed();
        await tester.pump();
        // Closing reads the count once more, for the lobby it returns to.
        expect(server.count('GET', '/api/friends/requests'), 4);
        await tester.pump(const Duration(minutes: 3));
        expect(server.count('GET', '/api/friends'), 3);
        expect(server.count('GET', '/api/friends/requests'), 4);
        state.dispose();
      }, () => server.client);
    });

    testWidgets('the lobby reads the count as it shows and every 60 s — not '
        'while the open page is reading it anyway — and not once it goes', (
      tester,
    ) async {
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        final friends = state.friends;
        int count() => server.count('GET', '/api/friends/requests');
        friends.lobbyShown();
        await tester.pump();
        expect(count(), 1);
        await tester.pump(const Duration(seconds: 59));
        expect(count(), 1);
        await tester.pump(const Duration(seconds: 1));
        expect(count(), 2);

        // The page opens: its own poll reads the requests every 15 s, and the
        // lobby's minute adds nothing to it.
        friends.pageOpened();
        await tester.pump();
        expect(count(), 3);
        await tester.pump(const Duration(seconds: 60));
        expect(count(), 7, reason: 'four polls in a minute, no badge read');
        friends.pageClosed();
        await tester.pump();
        expect(count(), 8);

        friends.lobbyHidden();
        await tester.pump(const Duration(minutes: 5));
        expect(count(), 8);
        expect(server.count('GET', '/api/friends'), 5);
        state.dispose();
      }, () => server.client);
    });

    testWidgets('a sign-in reads the count once, however many ask', (
      tester,
    ) async {
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        // The sign-in and the lobby appearing ask in the same moment.
        unawaited(state.friends.refreshBadge());
        state.friends.lobbyShown();
        await tester.pump();
        expect(server.count('GET', '/api/friends/requests'), 1);
        state.friends.lobbyHidden();
        state.dispose();
      }, () => server.client);
    });
  });

  group('the moves', () {
    test('a request sent stands as PENDING_SENT', () async {
      final server = populatedServer();
      server.players['u-ravi'] = {
        'player': cardJson('u-ravi', 'Ravi'),
        'friendStatus': 'NONE',
      };
      final state = signedInState();
      final friends = state.friends;
      await _on(server, () => friends.search('  u-ravi  '));
      expect(friends.lookup?.friendStatus, FriendStatus.none);
      // The Player ID was trimmed before it was asked for.
      expect(server.sent.last.url.path, '/api/players/u-ravi');

      final sent = await _on(server, () => friends.sendRequest('u-ravi'));
      expect(sent, isTrue);
      expect(friends.lookup?.friendStatus, FriendStatus.pendingSent);
      expect(friends.lookup?.requestId, '900');
      expect(friends.lookupNote, isNull);
      expect(friends.sendingTo, isNull);
      final post = server.sent.last;
      expect(post.method, 'POST');
      expect(jsonDecode(post.body), {'userId': 'u-ravi'});
      state.dispose();
    });

    test(
      'a refused request moves the player to what the refusal says',
      () async {
        final state = signedInState();
        final friends = state.friends;
        for (final (code, status, expected, requestId) in [
          ('already_friends', 409, FriendStatus.friends, null),
          ('request_already_sent', 409, FriendStatus.pendingSent, null),
          ('request_already_received', 409, FriendStatus.pendingReceived, '41'),
          ('self_request', 400, FriendStatus.self, null),
        ]) {
          final server = populatedServer()
            ..sendRefusal = refusal(
              code,
              status,
              requestId: code == 'request_already_received' ? 41 : null,
            );
          server.players['u-ravi'] = {
            'player': cardJson('u-ravi', 'Ravi'),
            'friendStatus': 'NONE',
          };
          await _on(server, () => friends.search('u-ravi'));
          final sent = await _on(server, () => friends.sendRequest('u-ravi'));
          expect(sent, isFalse, reason: code);
          expect(friends.lookup?.friendStatus, expected, reason: code);
          expect(friends.lookup?.requestId, requestId, reason: code);
          expect(friends.lookupNote, code, reason: code);
          expect(
            friendsRefusalText(state.t, friends.lookupNote),
            isNot(state.t.friendActionFailed),
            reason: code,
          );
        }
        state.dispose();
      },
    );

    test('an accept moves the request into the friend list, in its place, '
        'at once', () async {
      final server = populatedServer();
      final state = signedInState();
      final friends = state.friends;
      await _on(server, () => friends.refresh());
      final reads = server.count('GET', '/api/friends');
      final accepted = await _on(server, () => friends.accept('41'));
      expect(accepted, isTrue);
      expect(friends.incoming.map((r) => r.requestId), ['42']);
      expect(friends.incomingCount, 1);
      // PLAYING, ONLINE by name, OFFLINE — Ravi is online.
      expect(friends.friends.map((f) => f.displayName), [
        'Meera',
        'Arjun',
        'Ravi',
        'Kavya',
      ]);
      expect(server.count('GET', '/api/friends'), reads);
      expect(state.notice, 'Ravi is now your friend.');
      expect(friends.busyRequests, isEmpty);
      state.dispose();
    });

    test('a reject takes the request away at once, and says nothing', () async {
      final server = populatedServer();
      final state = signedInState();
      final friends = state.friends;
      await _on(server, () => friends.refresh());
      final rejected = await _on(server, () => friends.reject('42'));
      expect(rejected, isTrue);
      expect(friends.incoming.map((r) => r.requestId), ['41']);
      expect(friends.incomingCount, 1);
      expect(friends.friends, hasLength(3));
      expect(state.notice, isNull);
      expect(server.sent.last.url.path, '/api/friends/requests/42/reject');
      state.dispose();
    });

    test('a removal takes the friend off the list at once', () async {
      final server = populatedServer();
      final state = signedInState();
      final friends = state.friends;
      await _on(server, () => friends.refresh());
      final reads = server.count('GET', '/api/friends');
      final removed = await _on(server, () => friends.remove('u-kavya'));
      expect(removed, isTrue);
      expect(friends.friends.map((f) => f.userId), ['u-meera', 'u-arjun']);
      expect(server.count('GET', '/api/friends'), reads);
      expect(state.notice, 'Kavya is no longer your friend.');
      expect(server.sent.last.method, 'DELETE');
      expect(server.sent.last.url.path, '/api/friends/u-kavya');
      state.dispose();
    });

    test('a refused accept is said in the player\'s language, and the request '
        'that is gone goes from the page', () async {
      final server = populatedServer();
      final state = signedInState(lang: AppLang.hindi);
      final friends = state.friends;
      await _on(server, () => friends.refresh());
      server.answerRefusal = refusal('request_not_found', 404);
      final reads = server.count('GET', '/api/friends');
      final accepted = await _on(server, () async {
        final ok = await friends.accept('41');
        // The lists are read again to show what became of it.
        await friends.refresh();
        return ok;
      });
      expect(accepted, isFalse);
      expect(
        state.notice,
        const Strings(AppLang.hindi).friendRefuseRequestGone,
      );
      expect(server.count('GET', '/api/friends'), greaterThan(reads));
      state.dispose();
    });

    test(
      'a removal the other player already made is said, and shown',
      () async {
        final server = populatedServer();
        final state = signedInState();
        final friends = state.friends;
        await _on(server, () => friends.refresh());
        server.friends.removeWhere((f) => f['userId'] == 'u-kavya');
        final removed = await _on(server, () => friends.remove('u-kavya'));
        expect(removed, isFalse);
        expect(state.notice, state.t.friendRefuseNotFriends);
        expect(
          friends.friends.map((f) => f.userId),
          isNot(contains('u-kavya')),
        );
        state.dispose();
      },
    );

    testWidgets('a read that set out before a move does not undo it', (
      tester,
    ) async {
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        final friends = state.friends;
        await friends.refresh();
        await tester.pump();
        // A poll sets out and is held on the wire…
        server
          ..holdPath = '/api/friends'
          ..hold = Completer<void>();
        final poll = friends.refresh();
        await tester.pump();
        // …the player accepts meanwhile (the server has not seen it when
        // the held read is answered: it answers with the old lists)…
        final before = server.friends.toList();
        final beforeIncoming = server.incoming.toList();
        server.holdPath = null;
        await friends.accept('41');
        server.friends
          ..clear()
          ..addAll(before);
        server.incoming
          ..clear()
          ..addAll(beforeIncoming);
        server.holdPath = '/api/friends';
        // …and then the held read lands.
        server.hold!.complete();
        await poll;
        await tester.pump();
        expect(friends.incoming.map((r) => r.requestId), ['42']);
        expect(friends.friends.map((f) => f.displayName), contains('Ravi'));
        state.dispose();
      }, () => server.client);
    });
  });

  group('the search', () {
    test('nothing typed asks nothing; nobody found says so', () async {
      final server = populatedServer();
      final state = signedInState();
      final friends = state.friends;
      await _on(server, () => friends.search('   '));
      expect(server.sent, isEmpty);
      expect(friends.searchError, friendsEmptyId);
      await _on(server, () => friends.search('nobody'));
      expect(friends.lookup, isNull);
      expect(friends.searchError, 'player_not_found');
      expect(
        friendsRefusalText(state.t, friends.searchError),
        'Player not found.',
      );
      friends.clearSearch();
      expect(friends.searchError, isNull);
      state.dispose();
    });

    test('no answer is said as no connection', () async {
      final state = signedInState();
      final friends = state.friends;
      await http.runWithClient(
        () => friends.search('u-ravi'),
        () => throw const SocketLikeFailure(),
      );
      expect(friends.searchError, friendsNoAnswer);
      expect(
        friendsRefusalText(state.t, friendsNoAnswer),
        state.t.notConnected,
      );
      state.dispose();
    });
  });

  group('the page\'s lists', () {
    test('a first read that fails offers Retry; a poll that fails keeps the '
        'lists', () async {
      final server = populatedServer()..failLists = true;
      final state = signedInState();
      final friends = state.friends;
      await _on(server, () => friends.refresh());
      expect(friends.loaded, isFalse);
      expect(friends.failed, isTrue);
      server.failLists = false;
      await _on(server, () => friends.refresh());
      expect(friends.loaded, isTrue);
      expect(friends.failed, isFalse);
      server.failLists = true;
      await _on(server, () => friends.refresh());
      expect(friends.failed, isFalse);
      expect(friends.friends, hasLength(3));
      state.dispose();
    });

    test(
      'the profile shows where a friend is as the list last had it',
      () async {
        final server = populatedServer();
        final state = signedInState();
        final friends = state.friends;
        await _on(server, () => friends.refresh());
        await _on(server, () => friends.openProfile('u-meera'));
        expect(friends.profile?.stats.handsPlayed, 120);
        expect(friends.presenceOf('u-meera')?.isPlaying, isTrue);
        expect(friends.presenceOf('u-nobody'), isNull);
        friends.closeProfile();
        expect(friends.profile, isNull);
        expect(friends.profileFor, isNull);
        state.dispose();
      },
    );
  });

  test('signing out forgets this account\'s friends', () async {
    SharedPreferences.setMockInitialValues({'token': 'tok'});
    final server = populatedServer();
    final state = signedInState();
    final friends = state.friends;
    await _on(server, () => friends.refresh());
    expect(friends.friends, isNotEmpty);
    await state.signOut();
    expect(friends.friends, isEmpty);
    expect(friends.incoming, isEmpty);
    expect(friends.incomingCount, 0);
    expect(friends.loaded, isFalse);
    expect(friends.lookup, isNull);
    expect(friends.profile, isNull);
    state.dispose();
  });
}

/// A request that never reached the server.
class SocketLikeFailure implements Exception {
  const SocketLikeFailure();
}
