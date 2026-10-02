// Google sign-in on the iPhone (2 Oct 2026, owner: "sign in with google was
// not working in apple"). Two things stood in its way, and neither could be
// seen from Android:
//
//  * the server client id. On iOS the plugin drops the serverClientId Dart
//    passes unless a clientId comes with it, and Google's SDK then reads
//    Info.plist alone — so the Web client has to be named there, or the
//    token's audience is the iOS client and the server answers 401;
//  * the iOS client id. Without it Google's SDK raises, the plugin hands the
//    raise over as a bare PlatformException, and the login said "Could not
//    reach the server" about a server that was fine.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:teenpatti/net/social_sign_in.dart';

String _read(String path) => File(path).readAsStringSync();

/// The string under [key] in Info.plist.
String? _plistString(String plist, String key) => RegExp(
  '<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>',
).firstMatch(plist)?.group(1);

/// What `NAME=value` sets in an xcconfig, comments aside.
String? _setting(String xcconfig, String name) {
  for (final line in const LineSplitter().convert(xcconfig)) {
    final text = line.split('//').first.trim();
    if (text.startsWith('$name=')) {
      return text.substring(name.length + 1).trim();
    }
  }
  return null;
}

void main() {
  group('the iOS app\'s Info.plist', () {
    final plist = _read('ios/Runner/Info.plist');

    test('names the Web client as the server client id', () {
      expect(
        _plistString(plist, 'GIDServerClientID'),
        SocialSignIn.serverClientId,
        reason: 'the server checks the token\'s audience against this id',
      );
    });

    test('names the client every build configuration is given', () {
      for (final file in Directory('config').listSync().whereType<File>()) {
        if (!file.path.endsWith('.json')) continue;
        final config = jsonDecode(file.readAsStringSync()) as Map;
        expect(
          config['GOOGLE_SERVER_CLIENT_ID'],
          _plistString(plist, 'GIDServerClientID'),
          reason: file.path,
        );
      }
    });

    test('takes the iOS client and its URL scheme from the xcconfig', () {
      expect(_plistString(plist, 'GIDClientID'), r'$(GOOGLE_IOS_CLIENT_ID)');
      expect(plist, contains(r'<string>$(GOOGLE_IOS_URL_SCHEME)</string>'));
    });
  });

  group('the iOS client in Flutter/*.xcconfig', () {
    for (final name in ['Debug', 'Release']) {
      test('$name: unset, or a client id with its own URL scheme', () {
        final xcconfig = _read('ios/Flutter/$name.xcconfig');
        final id = _setting(xcconfig, 'GOOGLE_IOS_CLIENT_ID');
        final scheme = _setting(xcconfig, 'GOOGLE_IOS_URL_SCHEME');
        expect(id, isNotNull);
        expect(scheme, isNotNull);
        if (id!.isEmpty) {
          expect(scheme, isEmpty, reason: 'a scheme with no client');
          return;
        }
        const suffix = '.apps.googleusercontent.com';
        expect(id, endsWith(suffix));
        expect(
          id,
          isNot(SocialSignIn.serverClientId),
          reason: 'this is the iOS client, not the Web one',
        );
        // The scheme is the client id with its two halves swapped.
        expect(
          scheme,
          'com.googleusercontent.apps.'
          '${id.substring(0, id.length - suffix.length)}',
        );
      });
    }

    test('both configurations name the same client', () {
      final debug = _read('ios/Flutter/Debug.xcconfig');
      final release = _read('ios/Flutter/Release.xcconfig');
      for (final name in ['GOOGLE_IOS_CLIENT_ID', 'GOOGLE_IOS_URL_SCHEME']) {
        expect(_setting(debug, name), _setting(release, name), reason: name);
      }
    });
  });

  group('what the plugin answers', () {
    test('a token is handed on', () async {
      expect(await SocialSignIn.googleWith(() async => 'id-token'), 'id-token');
    });

    test('a build with no iOS client says Google is unavailable', () async {
      // Google's SDK, through the plugin's @catch, on a build whose
      // GIDClientID is empty.
      await expectLater(
        SocialSignIn.googleWith(
          () async => throw PlatformException(
            code: 'google_sign_in',
            message: 'You must specify |clientID| in |GIDConfiguration|',
            details: 'NSInvalidArgumentException',
          ),
        ),
        throwsA(
          isA<SignInUnavailable>().having(
            (e) => e.provider,
            'provider',
            'Google',
          ),
        ),
      );
    });

    test('a build with no URL scheme says the same', () async {
      await expectLater(
        SocialSignIn.googleWith(
          () async => throw PlatformException(
            code: 'google_sign_in',
            message:
                'Your app is missing support for the following URL schemes: '
                'com.googleusercontent.apps.1234-abc',
          ),
        ),
        throwsA(isA<SignInUnavailable>()),
      );
    });

    test('closing Google\'s sheet is the player\'s decision', () async {
      // iOS reports the closed sheet as canceled, with the SDK's own words.
      expect(
        await SocialSignIn.googleWith(
          () async => throw const GoogleSignInException(
            code: GoogleSignInExceptionCode.canceled,
            description: 'The user canceled the sign-in flow.',
          ),
        ),
        isNull,
      );
    });

    test('no ID token is the build\'s fault, said as such', () async {
      await expectLater(
        SocialSignIn.googleWith(() async => null),
        throwsA(isA<SignInUnavailable>()),
      );
    });

    test('a failure that is not the build\'s is passed on', () async {
      await expectLater(
        SocialSignIn.googleWith(
          () async => throw const GoogleSignInException(
            code: GoogleSignInExceptionCode.interrupted,
          ),
        ),
        throwsA(isA<GoogleSignInException>()),
      );
    });
  });
}
