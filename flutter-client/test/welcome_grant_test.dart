// The welcome grant (30 Sep 2026): the server gives a NEW account whatever
// its `welcome_rewards` rows say, and the login answer carries a `welcome`
// block — present only for a new account — of chips, diamonds, hammers,
// missiles and the pictures, table pictures and emojis granted, any of them
// 0 or empty. `welcomeChips` stays for older apps.
//
// These hold WelcomeGrant (models/dtos.dart) to a tolerant reading of that
// block; the toast (state/game_state.dart welcomeNotice) to naming exactly
// what was granted, in the player's language, singular and plural right —
// a plain welcome when nothing was, the chips alone from a server that
// predates the grant, and nothing for a returning account; and the
// catalogues to showing a granted picture owned once the sign-in lands, even
// when the cold start's anonymous read answers after the signed-in one.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/state/game_state.dart';

/// A socket that connects to nothing.
class _Socket extends GameConnection {
  _Socket() : super('http://127.0.0.1:9');

  final connects = <String>[];

  @override
  void connect(String token) => connects.add(token);

  @override
  void disconnect() {}
}

GameState _state({AppLang lang = AppLang.english}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(
    serverUrl: 'http://127.0.0.1:9',
    connection: _Socket(),
  );
  debugDefaultTargetPlatformOverride = null;
  return state..lang = lang;
}

const _userJson = {
  'id': 'u0',
  'provider': 'guest',
  'displayName': 'Ravi',
  'chips': 1000000,
};

/// A premium picture, table picture and emoji as the catalogues send them;
/// [owned] as the server resolves it for the asker.
Map<String, Object?> _picture({required bool owned}) => {
  'id': 7,
  'name': 'Lovestruck Cat',
  'url': 'https://example.test/cat.json',
  'assetFormat': 'LOTTIE',
  'currency': 'HAMMER',
  'type': 'PREMIUM',
  'cost': 50,
  'durationDays': 50,
  'durationHours': 0,
  'sortOrder': 230,
  'owned': owned,
  'expiresAt': owned ? 1900000000000 : 0,
};

Map<String, Object?> _tablePicture({required bool owned}) => {
  'id': 3,
  'name': 'Welcome',
  'dayUrl': 'https://example.test/welcome.json',
  'nightUrl': 'https://example.test/welcome.json',
  'assetFormat': 'LOTTIE',
  'currency': 'COIN',
  'type': 'PREMIUM',
  'cost': 150000,
  'durationDays': 7,
  'durationHours': 0,
  'sortOrder': 85,
  'owned': owned,
  'expiresAt': 0,
};

Map<String, Object?> _emoji(int id, {required bool owned}) => {
  'id': id,
  'name': 'Emoji $id',
  'url': 'https://example.test/e$id.json',
  'assetFormat': 'LOTTIE',
  'currency': 'HAMMER',
  'type': 'PREMIUM',
  'cost': 5,
  'durationDays': 30,
  'durationHours': 0,
  'sortOrder': id * 10,
  'owned': owned,
  'expiresAt': 0,
};

/// The owner's full welcome: every wallet, a picture, two emojis.
Map<String, Object?> _fullWelcome() => {
  'chips': 1000000,
  'diamonds': 9,
  'hammers': 20,
  'missiles': 1,
  'pictures': [_picture(owned: true)],
  'tablePictures': <Object?>[],
  'emojis': [_emoji(1, owned: true), _emoji(2, owned: true)],
};

/// The server: the login answers [login]; the catalogues answer per asker —
/// owned for a signed-in request, not for an anonymous one, which waits for
/// [anonymousGate] when it is given (the cold start's read, slow); every
/// other request is a 404.
class _Server {
  _Server(this.login);

  Map<String, Object?> login;
  Completer<void>? anonymousGate;

  MockClient get client => MockClient((request) async {
    final signedIn = request.headers['authorization'] != null;
    Future<http.Response> catalogue(Map<String, Object?> body) async {
      if (!signedIn && anonymousGate != null) await anonymousGate!.future;
      return http.Response(jsonEncode(body), 200, request: request);
    }

    switch (request.url.path) {
      case '/api/auth/login':
        return http.Response(jsonEncode(login), 200, request: request);
      case '/api/profiles':
        return catalogue({
          'profiles': [_picture(owned: signedIn)],
        });
      case '/api/table-pictures':
        return catalogue({
          'tablePictures': [_tablePicture(owned: signedIn)],
        });
      case '/api/emojis':
        return catalogue({
          'emojis': [_emoji(1, owned: signedIn), _emoji(2, owned: signedIn)],
        });
    }
    return http.Response('{"error":"not_found"}', 404, request: request);
  });
}

Map<String, Object?> _loginJson({
  bool isNew = true,
  int welcomeChips = 1000000,
  Object? welcome,
  bool withWelcome = true,
}) => {
  'token': 'tok-new',
  'user': _userJson,
  'isNew': isNew,
  'welcomeChips': welcomeChips,
  if (withWelcome) 'welcome': welcome,
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'King Teen Patti',
      packageName: 'com.sungamestudio.kingteenpatti',
      version: '1.7.0',
      buildNumber: '17',
      buildSignature: '',
    );
  });

  group('WelcomeGrant', () {
    test('reads a full block: every wallet and every catalogue row', () {
      final grant = WelcomeGrant.fromJson({
        ..._fullWelcome(),
        'tablePictures': [_tablePicture(owned: true)],
      })!;
      expect(grant.chips, 1000000);
      expect(grant.diamonds, 9);
      expect(grant.hammers, 20);
      expect(grant.missiles, 1);
      expect(grant.pictures.single.name, 'Lovestruck Cat');
      expect(grant.pictures.single.owned, isTrue);
      expect(grant.tablePictures.single.name, 'Welcome');
      expect(grant.tablePictures.single.dayUrl, isNotEmpty);
      expect(grant.emojis.map((e) => e.id), [1, 2]);
      expect(grant.isEmpty, isFalse);
    });

    test('reads a partial block: what is missing is 0 or empty', () {
      final grant = WelcomeGrant.fromJson({'chips': 500000, 'hammers': 5})!;
      expect(grant.chips, 500000);
      expect(grant.hammers, 5);
      expect(grant.diamonds, 0);
      expect(grant.missiles, 0);
      expect(grant.pictures, isEmpty);
      expect(grant.tablePictures, isEmpty);
      expect(grant.emojis, isEmpty);
      expect(grant.isEmpty, isFalse);
    });

    test('an empty block is a grant of nothing, not no grant', () {
      final grant = WelcomeGrant.fromJson(const <String, Object?>{})!;
      expect(grant.isEmpty, isTrue);
      final zeros = WelcomeGrant.fromJson(const {
        'chips': 0,
        'diamonds': 0,
        'hammers': 0,
        'missiles': 0,
        'pictures': <Object?>[],
        'tablePictures': <Object?>[],
        'emojis': <Object?>[],
      })!;
      expect(zeros.isEmpty, isTrue);
    });

    test(
      'an absent block — a returning account, an older server — is null',
      () {
        expect(WelcomeGrant.fromJson(null), isNull);
        expect(
          WelcomeGrant.fromJson(_loginJson(withWelcome: false)['welcome']),
          isNull,
        );
      },
    );

    test('junk reads as less, never as a failure', () {
      expect(WelcomeGrant.fromJson('welcome'), isNull);
      expect(WelcomeGrant.fromJson(const [1, 2]), isNull);
      expect(WelcomeGrant.fromJson(42), isNull);
      final grant = WelcomeGrant.fromJson({
        'chips': '1000000',
        'diamonds': -9,
        'hammers': 20.0,
        'missiles': null,
        'pictures': 'Lovestruck Cat',
        'tablePictures': {'id': 3},
        'emojis': [_emoji(1, owned: true), 'Angry', 7, null],
      })!;
      expect(grant.chips, 0, reason: 'a figure as text is not a figure');
      expect(grant.diamonds, 0, reason: 'nothing is taken at a welcome');
      expect(grant.hammers, 20);
      expect(grant.missiles, 0);
      expect(grant.pictures, isEmpty);
      expect(grant.tablePictures, isEmpty);
      expect(grant.emojis.single.id, 1);
    });

    test('the login answer carries it, and welcomeChips beside it', () async {
      final server = _Server(_loginJson(welcome: _fullWelcome()));
      final r = await http.runWithClient(
        () => ApiClient('http://127.0.0.1:9').loginGuest(deviceId: 'device-01'),
        () => server.client,
      );
      expect(r.isNew, isTrue);
      expect(r.welcomeChips, 1000000);
      expect(r.welcome?.diamonds, 9);
      expect(r.welcome?.emojis, hasLength(2));

      server.login = _loginJson(
        isNew: false,
        welcomeChips: 0,
        withWelcome: false,
      );
      final back = await http.runWithClient(
        () => ApiClient(
          'http://127.0.0.1:9',
        ).loginProvider(provider: 'google', credential: 'id-token'),
        () => server.client,
      );
      expect(back.welcome, isNull);
      expect(back.welcomeChips, 0);
    });
  });

  group('the toast', () {
    const en = Strings(AppLang.english);
    const hi = Strings(AppLang.hindi);
    final full = WelcomeGrant.fromJson(_fullWelcome());
    final lakh10 = formatChips(1000000);

    test('a full grant names every part of it, in English and Hindi', () {
      expect(
        welcomeNotice(en, full),
        'Welcome! Added to your account: $lakh10 chips · 9 diamonds · '
        '20 hammers · 1 missile · 1 picture · 2 emojis',
      );
      expect(
        welcomeNotice(hi, full),
        'स्वागत है! आपके खाते में जोड़ा गया: $lakh10 चिप्स · 9 हीरे · '
        '20 हथौड़े · 1 मिसाइल · 1 तस्वीर · 2 इमोजी',
      );
    });

    test('a partial grant names what it gave and nothing it did not', () {
      final partial = WelcomeGrant.fromJson({
        'hammers': 1,
        'diamonds': 1,
        'tablePictures': [_tablePicture(owned: true)],
        'pictures': [_picture(owned: true), _picture(owned: true)],
      });
      expect(
        welcomeNotice(en, partial),
        'Welcome! Added to your account: 1 diamond · 1 hammer · '
        '2 pictures · 1 table picture',
      );
      expect(
        welcomeNotice(hi, partial),
        'स्वागत है! आपके खाते में जोड़ा गया: 1 हीरा · 1 हथौड़ा · '
        '2 तस्वीरें · 1 टेबल की तस्वीर',
      );
      final missiles = WelcomeGrant.fromJson({
        'missiles': 3,
        'emojis': [_emoji(1, owned: true)],
      });
      expect(
        welcomeNotice(en, missiles),
        'Welcome! Added to your account: 3 missiles · 1 emoji',
      );
      expect(
        welcomeNotice(hi, missiles),
        'स्वागत है! आपके खाते में जोड़ा गया: 3 मिसाइलें · 1 इमोजी',
      );
    });

    test('a grant of nothing is a plain welcome with no list', () {
      final none = WelcomeGrant.fromJson(const <String, Object?>{});
      expect(welcomeNotice(en, none), 'Welcome to King Teen Patti!');
      expect(welcomeNotice(hi, none), 'King Teen Patti में आपका स्वागत है!');
      // welcomeChips from the same answer does not add a list the grant lacks.
      expect(
        welcomeNotice(en, none, welcomeChips: 1000000),
        'Welcome to King Teen Patti!',
      );
    });

    test('a server from before the grant: the chips alone, or nothing', () {
      expect(
        welcomeNotice(en, null, welcomeChips: 1000000),
        'Welcome! Added to your account: $lakh10 chips',
      );
      expect(
        welcomeNotice(hi, null, welcomeChips: 1000000),
        'स्वागत है! आपके खाते में जोड़ा गया: $lakh10 चिप्स',
      );
      expect(welcomeNotice(en, null), isNull);
      expect(welcomeNotice(hi, null, welcomeChips: 0), isNull);
    });

    test('every language has every word, and one of each thing says one', () {
      const keys = [
        'welcomeAdded',
        'welcomePlain',
        'countPictureOne',
        'countPictures',
        'countTablePictureOne',
        'countTablePictures',
        'countEmojiOne',
        'countEmojis',
      ];
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        for (final key in keys) {
          expect(t.ownEntry(key), isNotNull, reason: '${lang.code} $key');
        }
        expect(t.welcomeAdded('X'), contains('X'), reason: lang.code);
        expect(t.welcomeAdded('X'), isNot(contains('{items}')));
        for (final count in [
          t.countPictures,
          t.countTablePictures,
          t.countEmojis,
        ]) {
          expect(count(1), contains('1'), reason: lang.code);
          expect(count(1), isNot(contains('{n}')));
          expect(count(7), contains('7'), reason: lang.code);
          expect(count(7), isNot(contains('{n}')));
        }
        // A full grant in every language: each part in its place, no key or
        // placeholder showing through.
        final text = welcomeNotice(t, full)!;
        expect(text, isNot(contains('{')), reason: lang.code);
        expect(text.split(' · '), hasLength(6), reason: lang.code);
        expect(
          welcomeNotice(t, WelcomeGrant.fromJson(const {})),
          t.welcomePlain,
        );
      }
      // English says one of each in the singular and many in the plural.
      expect(en.countPictures(1), '1 picture');
      expect(en.countPictures(2), '2 pictures');
      expect(en.countTablePictures(1), '1 table picture');
      expect(en.countTablePictures(3), '3 table pictures');
      expect(en.countEmojis(1), '1 emoji');
      expect(en.countEmojis(2), '2 emojis');
      expect(hi.countPictures(1), '1 तस्वीर');
      expect(hi.countPictures(2), '2 तस्वीरें');
    });
  });

  group('signing in', () {
    test(
      'a new guest account hears what it was given, in its language',
      () async {
        final state = _state(lang: AppLang.hindi);
        addTearDown(state.dispose);
        final server = _Server(_loginJson(welcome: _fullWelcome()));
        await http.runWithClient(
          () => state.loginAsGuest('Ravi'),
          () => server.client,
        );
        // The sign-in's own reads (catalogues, the draw, the ladder) finish
        // before the state is disposed.
        await pumpEventQueue();
        expect(state.screen, Screen.lobby);
        expect(
          state.notice,
          welcomeNotice(
            const Strings(AppLang.hindi),
            WelcomeGrant.fromJson(_fullWelcome()),
          ),
        );
        expect(
          state.notice,
          startsWith('स्वागत है! आपके खाते में जोड़ा गया: '),
        );
        expect(state.notice, isNot(contains('Welcome')));
      },
    );

    test('a new Google account hears it too', () async {
      final state = _state();
      addTearDown(state.dispose);
      final server = _Server(
        _loginJson(welcome: {'chips': 1000000, 'missiles': 1}),
      );
      await http.runWithClient(
        () => state.loginWithProvider('google', () async => 'id-token'),
        () => server.client,
      );
      // The sign-in's own reads (catalogues, the draw, the ladder) finish
      // before the state is disposed.
      await pumpEventQueue();
      expect(
        state.notice,
        'Welcome! Added to your account: ${formatChips(1000000)} chips · '
        '1 missile',
      );
    });

    test('a new account granted nothing is simply welcomed', () async {
      final state = _state();
      addTearDown(state.dispose);
      final server = _Server(
        _loginJson(welcomeChips: 0, welcome: const <String, Object?>{}),
      );
      await http.runWithClient(
        () => state.loginAsGuest('Ravi'),
        () => server.client,
      );
      // The sign-in's own reads (catalogues, the draw, the ladder) finish
      // before the state is disposed.
      await pumpEventQueue();
      expect(state.notice, 'Welcome to King Teen Patti!');
    });

    test('an older server\'s new account hears its chips alone', () async {
      final state = _state();
      addTearDown(state.dispose);
      final server = _Server(_loginJson(withWelcome: false));
      await http.runWithClient(
        () => state.loginAsGuest('Ravi'),
        () => server.client,
      );
      // The sign-in's own reads (catalogues, the draw, the ladder) finish
      // before the state is disposed.
      await pumpEventQueue();
      expect(
        state.notice,
        'Welcome! Added to your account: ${formatChips(1000000)} chips',
      );
    });

    test('a returning account hears nothing', () async {
      for (final login in [
        _loginJson(isNew: false, welcomeChips: 0, withWelcome: false),
        // Even a server that wrongly sent the block on a returning login.
        _loginJson(isNew: false, welcome: _fullWelcome()),
      ]) {
        final state = _state();
        addTearDown(state.dispose);
        await http.runWithClient(
          () => state.loginAsGuest('Ravi'),
          () => _Server(login).client,
        );
        // The sign-in's own reads (catalogues, the draw, the ladder) finish
        // before the state is disposed.
        await pumpEventQueue();
        expect(state.screen, Screen.lobby);
        expect(state.notice, isNull);
      }
    });

    test('what the welcome gave shows owned once the sign-in lands, even when '
        'the cold start\'s anonymous read answers after it', () async {
      final state = _state();
      addTearDown(state.dispose);
      final server = _Server(_loginJson(welcome: _fullWelcome()))
        ..anonymousGate = Completer<void>();
      // A cold start with no saved session: the catalogues are read with no
      // token, and that read is slow.
      await http.runWithClient(state.start, () => server.client);
      expect(state.screen, Screen.login);
      await http.runWithClient(
        () => state.loginAsGuest('Ravi'),
        () => server.client,
      );
      // The sign-in's own reads (catalogues, the draw, the ladder) finish
      // before the state is disposed.
      await pumpEventQueue();
      await pumpEventQueue();
      expect(state.pictures.single.owned, isTrue);
      expect(state.tablePictures.single.owned, isTrue);
      expect(state.emojis.every((e) => e.owned), isTrue);

      // The anonymous answer, about nobody, arrives last and changes nothing.
      server.anonymousGate!.complete();
      await pumpEventQueue();
      expect(state.pictures.single.owned, isTrue);
      expect(state.tablePictures.single.owned, isTrue);
      expect(state.emojis.every((e) => e.owned), isTrue);
    });
  });
}
