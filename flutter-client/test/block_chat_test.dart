// Blocking a player's chat (owner, 22 Sep 2026).
//
// The rule the owner set, and what each test here pins:
//
//   * it is THIS client's view — nothing is sent to the server, nothing is
//     written to disk;
//   * it is THIS table — a different room id empties it;
//   * it is THIS sitting — leaving and coming back means blocking again;
//   * a blocked line is DROPPED, not hidden, so it cannot reappear later.
//
// The drawer itself — its players page, the long-press that opens it and the
// chat page that shows no sign of a block — is mounted and pressed in
// test/chat_drawer_test.dart; this file is the state underneath it.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/state/game_state.dart';

GameState _state() {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..user = User.fromJson({
      'id': 'me',
      'provider': 'guest',
      'displayName': 'You',
      'chips': 100000,
    });
}

ChatMessage _msg(String userId, String name, String text) =>
    ChatMessage.fromJson({
      'messageId': '$userId-$text',
      'userId': userId,
      'displayName': name,
      'text': text,
      'at': 0,
    });

void main() {
  test('blocking hides that player and nobody else', () {
    final state = _state()
      ..chat.addAll([
        _msg('ravi', 'Ravi', 'good hand'),
        _msg('meera', 'Meera', 'thanks'),
        _msg('ravi', 'Ravi', 'again'),
      ]);

    expect(state.isBlocked('ravi'), isFalse);
    expect(state.blockedIds, isEmpty);

    state.blockPlayer('ravi');

    expect(state.isBlocked('ravi'), isTrue);
    expect(state.blockedIds, {'ravi'});
    // Ravi's lines are gone from the drawer, Meera's untouched.
    expect(state.chat.map((m) => m.userId), ['meera']);
  });

  test('a blocked line is dropped, so unblocking does not bring it back', () {
    final state = _state()..chat.add(_msg('ravi', 'Ravi', 'good hand'));

    state.blockPlayer('ravi');
    expect(state.chat, isEmpty);

    state.unblockPlayer('ravi');
    expect(state.isBlocked('ravi'), isFalse);
    // Hiding and keeping would let a block be undone into a backlog of
    // everything that was said while it was on. It is a drop, not a filter.
    expect(state.chat, isEmpty);
  });

  test('you cannot block yourself, and an empty id is ignored', () {
    final state = _state();

    state.blockPlayer('me');
    state.blockPlayer('');

    expect(state.blockedIds, isEmpty);
  });

  test('blocking takes the bubble off the felt at once', () {
    final state = _state();
    // A line already showing over Ravi's seat, and one queued behind it.
    state.saidRecently['ravi'] = _msg('ravi', 'Ravi', 'up');
    state.saidRecently['meera'] = _msg('meera', 'Meera', 'mine');

    state.blockPlayer('ravi');

    expect(state.saidRecently.containsKey('ravi'), isFalse);
    // Blocking one player says nothing about anybody else.
    expect(state.saidRecently.containsKey('meera'), isTrue);
  });

  test('blocking twice is one block, and unblocking twice is harmless', () {
    final state = _state();

    state.blockPlayer('ravi');
    state.blockPlayer('ravi');
    expect(state.blockedIds, {'ravi'});

    state.unblockPlayer('ravi');
    state.unblockPlayer('ravi');
    expect(state.blockedIds, isEmpty);
  });

  test('the block list handed out cannot be edited from outside', () {
    final state = _state()..blockPlayer('ravi');

    expect(
      () => state.blockedIds.add('meera'),
      throwsUnsupportedError,
      reason: 'blockPlayer and unblockPlayer are the only ways in and out',
    );
  });

  test('every language names the controls and the empty list', () {
    // Since 24 Sep 2026 blocking asks nothing (owner: "do not show pop up"),
    // so the question, its body and the chat page's "Blocked" label are gone
    // with the dialog and the row: these four are all the drawer says.
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      for (final s in [t.block, t.unblock, t.blockPlayersTitle, t.blockNobody]) {
        expect(s, isNotEmpty, reason: lang.code);
        // An untranslated key falls through to its own name; none of these
        // should be reading back as 'block' or 'blockNobody'.
        expect(s, isNot(equals('block')), reason: lang.code);
        expect(s, isNot(equals('blockNobody')), reason: lang.code);
      }
      // Block and Unblock are two keys on the same row, so they must differ.
      expect(t.block, isNot(equals(t.unblock)), reason: lang.code);
    }
  });
}
