// The missile on the client (owner, 14 Sep 2026): the store's shelf of
// trades, the wire fields that carry missiles, the refusals, the REST trade,
// and the numbers the volley is timed and aimed by.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/state/missile_strike.dart';
import 'package:teenpatti/widgets/chip_store.dart';
import 'package:teenpatti/widgets/missile_flight.dart';

Map<String, dynamic> _user({Object? missile, int diamond = 2}) => {
  'id': 'u1',
  'provider': 'guest',
  'displayName': 'Ravi',
  'chips': 200000,
  'diamond': diamond,
  'hammer': 20,
  'missile': ?missile,
  'activePictureId': 7,
  'handsPlayed': 12,
  'biggestPot': 9000,
};

Map<String, dynamic> _you({
  Object? canMissile,
  Map<String, dynamic>? options,
}) => {
  'seatIndex': 0,
  'chips': 200000,
  'status': 'active',
  'isBlind': true,
  'blindMovesLeft': 4,
  'contributed': 400,
  'missedTurns': 0,
  'maxMissedTurns': 3,
  'cards': const [],
  'canMissile': ?canMissile,
  'options': ?options,
};

const _options = {
  'canSee': true,
  'canPack': true,
  'canSideshow': false,
  'sideshowWith': null,
  'raiseSteps': [200, 400],
  'show': null,
  'chips': 200000,
  'currentStake': 200,
};

GameState _newState() {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state;
}

RoomState _room({required bool onTurn, required bool canMissile}) =>
    RoomState.fromJson({
      'roomId': 'r1',
      'code': 'ABCD2345',
      'category': 'blind',
      'state': 'betting',
      'handNo': 3,
      'pot': 1200,
      'stake': 200,
      'you': _you(
        canMissile: canMissile,
        options: onTurn ? Map<String, dynamic>.from(_options) : null,
      ),
      'seats': const [],
    });

void main() {
  group('the missile shelf', () {
    test('is the four trades, cheapest first', () {
      expect(
        [for (final p in missilePacks) (p.packId, p.diamonds, p.missiles)],
        [
          ('missiles_1', 15, 1),
          ('missiles_5', 73, 5),
          ('missiles_10', 140, 10),
          ('missiles_20', 220, 20),
        ],
      );
    });

    test('starts at 15 diamonds a missile, and gives more a diamond up the '
        'shelf', () {
      // The base rate the blurb states is the single missile's price.
      expect(diamondsPerMissile, 15);
      expect(missilePacks.first.diamonds, diamondsPerMissile);
      expect(missilePacks.first.missiles, 1);
      // Not a flat rate any more (owner, 14 Sep 2026): each pack buys more
      // missiles a diamond than the one before it.
      for (var i = 1; i < missilePacks.length; i++) {
        final before = missilePacks[i - 1];
        final pack = missilePacks[i];
        expect(
          pack.missiles / pack.diamonds,
          greaterThan(before.missiles / before.diamonds),
          reason: pack.packId,
        );
      }
      for (final p in missilePacks) {
        expect(p.packId, 'missiles_${p.missiles}');
      }
      final ids = [
        ...chipPacks.map((p) => p.productId),
        ...diamondPacks.map((p) => p.productId),
        ...hammerPacks.map((p) => p.productId),
        ...missilePacks.map((p) => p.packId),
      ];
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('sits between Hammers and Pictures among the store tabs', () {
      expect(
        StoreTab.values.indexOf(StoreTab.missiles),
        StoreTab.values.indexOf(StoreTab.hammers) + 1,
      );
      expect(
        StoreTab.values.indexOf(StoreTab.pictures),
        StoreTab.values.indexOf(StoreTab.missiles) + 1,
      );
      // Tables (owner, 15 Sep 2026) follows, and Emojis (owner, 26 Sep 2026)
      // closes the row.
      expect(
        StoreTab.values.indexOf(StoreTab.tables),
        StoreTab.values.indexOf(StoreTab.pictures) + 1,
      );
      expect(StoreTab.values.last, StoreTab.emojis);
    });
  });

  group('the wire', () {
    test('a user carries its missiles, and an older server none', () {
      expect(User.fromJson(_user(missile: 1)).missile, 1);
      expect(User.fromJson(_user()).missile, 0);
      expect(User.fromJson(_user(missile: 'lots')).missile, 0);
    });

    test('withMissile changes the count and nothing else', () {
      final before = User.fromJson(_user(missile: 3));
      final after = before.withMissile(2);
      expect(after.missile, 2);
      expect(after.id, before.id);
      expect(after.chips, before.chips);
      expect(after.diamond, before.diamond);
      expect(after.hammer, before.hammer);
      expect(after.activePictureId, before.activePictureId);
      expect(after.handsPlayed, before.handsPlayed);
      expect(after.biggestPot, before.biggestPot);
      expect(before.withMissile(-1).missile, 0);
      // And spending a hammer keeps the missiles.
      expect(before.withHammer(19).missile, 3);
    });

    test('you.canMissile says whether the rules allow a missile', () {
      expect(You.fromJson(_you(canMissile: true)).canMissile, isTrue);
      expect(You.fromJson(_you(canMissile: false)).canMissile, isFalse);
      // A server that predates it sends nothing, and the key stays dark.
      expect(You.fromJson(_you()).canMissile, isFalse);
      // The same flag among the options is read too.
      expect(
        You.fromJson(
          _you(options: {..._options, 'canMissile': true}),
        ).canMissile,
        isTrue,
      );
      expect(
        TurnOptions.fromJson({..._options, 'canMissile': true}).canMissile,
        isTrue,
      );
    });

    test('the missile is its own action on the wire', () {
      expect(GameAction.missile, 'missile');
      expect(missileCost, 1);
    });
  });

  group('the key', () {
    test('may fire only on the turn the server allows it', () {
      final state = _newState()
        ..user = User.fromJson(_user(missile: 1))
        ..room = _room(onTurn: true, canMissile: true);
      expect(state.canMissile, isTrue);
      expect(state.hasMissile, isTrue);

      state.room = _room(onTurn: true, canMissile: false);
      expect(state.canMissile, isFalse);

      // Off turn the server's flag is not enough on its own.
      state.room = _room(onTurn: false, canMissile: true);
      expect(state.canMissile, isFalse);

      state
        ..room = _room(onTurn: true, canMissile: true)
        ..user = User.fromJson(_user(missile: 0));
      expect(state.canMissile, isTrue);
      expect(state.hasMissile, isFalse);
      state.dispose();
    });
  });

  group('refusals', () {
    test('no_missiles and too_few_players are said in every language', () {
      final state = _newState();
      for (final lang in AppLang.values) {
        state.lang = lang;
        final t = Strings(lang);
        expect(state.refusalText('no_missiles', 'No missiles'), t.noMissiles);
        expect(
          state.refusalText('too_few_players', 'Too few players'),
          t.tooFewPlayers,
        );
        // A missile needs the chips a show would cost (owner, 14 Sep 2026).
        expect(t.missileNeedsShowChips, isNot('missileNeedsShowChips'));
        if (lang != AppLang.english) {
          expect(
            t.missileNeedsShowChips,
            isNot(const Strings(AppLang.english).missileNeedsShowChips),
            reason: '${lang.name} has words of its own',
          );
        }
      }
      // A code with no words of its own keeps the server's message.
      expect(
        state.refusalText('not_your_turn', 'Not your turn'),
        'Not your turn',
      );
      state.dispose();
    });
  });

  group('the table line', () {
    Seat seat(int index, String id, String name) => Seat.fromJson({
      'seatIndex': index,
      'userId': id,
      'displayName': name,
      'status': 'active',
      'cardCount': 3,
    });
    final seats = [seat(0, 'u1', 'Ravi'), seat(1, 'u2', 'Meera')];
    const t = Strings(AppLang.english);

    test('tells the player who fired, and everyone else who did', () {
      expect(
        missileFiredLine(t, viewerId: 'u1', fromUserId: 'u1', seats: seats),
        'You fired a missile',
      );
      for (final viewer in ['u2', null]) {
        expect(
          missileFiredLine(t, viewerId: viewer, fromUserId: 'u1', seats: seats),
          'Ravi fired a missile',
        );
      }
      expect(
        missileFiredLine(t, viewerId: 'u2', fromUserId: 'u9', seats: seats),
        isNull,
      );
    });
  });

  group('POST /api/store/missiles', () {
    test('sends the pack and the request id, and reads the answer', () async {
      late http.Request sent;
      final client = MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'user': _user(missile: 11, diamond: 0),
            'charged': true,
            'diamonds': 140,
            'missiles': 10,
          }),
          200,
        );
      });
      final r = await http.runWithClient(
        () => ApiClient(
          'http://api.test',
        ).tradeMissiles('tok', 'missiles_10', 'req-1'),
        () => client,
      );

      expect(sent.method, 'POST');
      expect(sent.url.toString(), 'http://api.test/api/store/missiles');
      expect(sent.headers['Authorization'], 'Bearer tok');
      expect(jsonDecode(sent.body), {
        'packId': 'missiles_10',
        'requestId': 'req-1',
      });
      expect(r.charged, isTrue);
      expect(r.diamonds, 140);
      expect(r.missiles, 10);
      expect(r.user.missile, 11);
      expect(r.user.diamond, 0);
    });

    test('a replay answers uncharged, which is still the missiles', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'user': _user(missile: 11),
            'charged': false,
            'diamonds': 140,
            'missiles': 10,
          }),
          200,
        ),
      );
      final r = await http.runWithClient(
        () => ApiClient(
          'http://api.test',
        ).tradeMissiles('tok', 'missiles_10', 'r'),
        () => client,
      );
      expect(r.charged, isFalse);
      expect(r.user.missile, 11);
    });

    for (final (status, code) in [
      (409, 'not_enough_diamonds'),
      (400, 'unknown_pack'),
      (400, 'invalid_request_id'),
    ]) {
      test('a $status $code refusal carries its code', () async {
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode({'error': code, 'message': 'Refused'}),
            status,
          ),
        );
        await expectLater(
          http.runWithClient(
            () => ApiClient(
              'http://api.test',
            ).tradeMissiles('tok', 'missiles_20', 'r'),
            () => client,
          ),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.status, 'status', status)
                .having((e) => e.message, 'message', 'Refused'),
          ),
        );
      });
    }
  });

  group('the volley', () {
    test('is timed from the stagger and the flight', () {
      // 1.3 s in the air, a 0.44 s explosion, then the winner (owner).
      expect(MissileTiming.impact(0), const Duration(milliseconds: 1300));
      expect(MissileTiming.impact(3), const Duration(milliseconds: 1510));
      expect(MissileTiming.lastImpact(1), const Duration(milliseconds: 1300));
      expect(MissileTiming.lastImpact(4), const Duration(milliseconds: 1510));
      expect(MissileTiming.reveal(4), const Duration(milliseconds: 1950));
      expect(MissileTiming.total(4), const Duration(milliseconds: 2030));
      expect(MissileTiming.share(MissileTiming.total(2), 2), closeTo(1, 1e-9));
    });

    test('turns the drawing to face the way it flies', () {
      // The drawing's nose is up and to the right: flying that way needs no
      // turn, flying right a quarter turn less of it.
      expect(MissilePainter.headingFor(const Offset(1, -1)), closeTo(0, 1e-9));
      expect(
        MissilePainter.headingFor(const Offset(1, 0)),
        closeTo(math.pi / 4, 1e-9),
      );
      expect(
        MissilePainter.headingFor(const Offset(0, 1)),
        closeTo(3 * math.pi / 4, 1e-9),
      );
    });

    test('arcs a sideways flight up and a steep one outwards, on the felt', () {
      const stage = Size(600, 400);
      const podW = 85.0;
      final c = MissilePainter.control(
        const Offset(100, 300),
        const Offset(500, 300),
        stage: stage,
        podWidth: podW,
        index: 0,
      );
      expect(c.dx, closeTo(300, 1e-9));
      expect(c.dy, lessThan(300), reason: 'a sideways flight arcs up');
      expect(c.dy, greaterThanOrEqualTo(podW * 0.35));

      final up = MissilePainter.control(
        const Offset(100, 80),
        const Offset(500, 80),
        stage: stage,
        podWidth: podW,
        index: 0,
      );
      expect(up.dy, lessThan(80));
      expect(up.dy, greaterThanOrEqualTo(podW * 0.35));

      // A steep flight on the left of the felt bows out to the left, one on
      // the right to the right.
      final left = MissilePainter.control(
        const Offset(150, 350),
        const Offset(160, 60),
        stage: stage,
        podWidth: podW,
        index: 0,
      );
      expect(left.dx, lessThan(150));
      expect(left.dx, greaterThanOrEqualTo(podW * 0.35));
      final right = MissilePainter.control(
        const Offset(450, 350),
        const Offset(440, 60),
        stage: stage,
        podWidth: podW,
        index: 0,
      );
      expect(right.dx, greaterThan(450));
    });

    test('eases along its curve, one missile after another', () {
      // Read from the timing table, so a change to the flight moves this too.
      final flight = MissileTiming.flight.inMilliseconds;
      final stagger = MissileTiming.stagger.inMilliseconds;
      expect(MissilePainter.progressAt(-1, 0), isNull);
      expect(MissilePainter.progressAt(0, 0), 0);
      expect(MissilePainter.progressAt((flight / 2), 0), closeTo(0.5, 1e-9));
      expect(
        MissilePainter.progressAt(flight.toDouble(), 0),
        isNull,
        reason: 'landed',
      );
      expect(
        MissilePainter.progressAt((stagger - 10).toDouble(), 1),
        isNull,
        reason: 'not yet',
      );
      expect(
        MissilePainter.progressAt((stagger + flight - 10).toDouble(), 1)!,
        lessThan(1),
      );
      expect(
        MissilePainter.progressAt((stagger + flight).toDouble(), 1),
        isNull,
        reason: 'landed',
      );
    });
  });
}
