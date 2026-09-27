// The player's own Google photo on the picture shelf (owner, 28 Sep 2026:
// "in profile picture selection show his google profile image also, which he
// can select again after selecting different profile picture"). It leads the
// All shelf — the picker's and the store's Pictures shelf alike — as a tile
// like any free picture: "✓ Wearing" when no catalogue picture is worn (the
// account's face then IS that photo), "✓ Owned" otherwise, and a tap takes
// the catalogue picture off (POST /api/profile/avatar {avatar: null}). A guest
// has no such photo, and the priced shelves never show it.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';

const _googleUrl = 'https://lh3.googleusercontent.com/a/photo-of-suraj=s96-c';

/// A 1x1 PNG, so the photo draws without a network.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

ProfilePicture _picture(int id, String name, {bool free = true}) =>
    ProfilePicture(
      id: id,
      name: name,
      url: '',
      assetFormat: 'SVG',
      type: free ? 'FREE' : 'PREMIUM',
      cost: free ? 0 : 25000,
      durationDays: 0,
      owned: free,
      expiresAt: 0,
    );

Map<String, Object?> _userJson({
  String provider = 'google',
  int? wearing,
  String? photo = _googleUrl,
}) => {
  'id': 'u1',
  'provider': provider,
  'displayName': 'Suraj Kumar',
  'chips': 999000,
  'diamond': 9,
  'hammer': 20,
  'activePictureId': wearing,
  'avatarUrl': wearing == null ? photo : '',
  'providerAvatarUrl': photo,
};

GameState _state({
  String provider = 'google',
  int? wearing,
  AppLang lang = AppLang.english,
}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = Screen.lobby
    ..debugToken = 'token-1'
    ..pictures = [
      _picture(1, 'Bear'),
      _picture(2, 'Cat'),
      _picture(3, 'Fox', free: false),
    ]
    ..user = User.fromJson(_userJson(provider: provider, wearing: wearing));
}

Future<BuildContext> _host(WidgetTester tester, GameState state) async {
  late BuildContext host;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(
          value: FeedbackSettings(),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withScriptFallback(AppTheme.dark(sound: false)),
        builder: (context, child) => GlassBudget(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: child,
          ),
        ),
        home: Builder(
          builder: (context) {
            host = context;
            return const SizedBox.expand();
          },
        ),
      ),
    ),
  );
  return host;
}

Future<void> _openPicker(WidgetTester tester, GameState state) async {
  final host = await _host(tester, state);
  openPicturePicker(host);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
}

Future<void> _close(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
  state.dispose();
}

Finder _tileNamed(String name) => find
    .ancestor(of: find.text(name), matching: find.byType(PictureChoice))
    .first;

ShelfBadge _badgeOf(WidgetTester tester, Finder tile) =>
    tester.widget(find.descendant(of: tile, matching: find.byType(ShelfBadge)));

void main() {
  setUpAll(loadScriptFonts);
  setUp(() => PictureCache.prime(_googleUrl, _png));

  testWidgets('the Google photo leads the All shelf, worn while no catalogue '
      'picture is', (tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _state();
    await _openPicker(tester, state);

    final google = _tileNamed('Google photo');
    expect(google, findsOneWidget);
    expect(
      tester.widget<PictureChoice>(google).picture.url,
      _googleUrl,
      reason: 'the photo Google gave the account',
    );
    final badge = _badgeOf(tester, google);
    expect(badge.kind, ShelfBadgeKind.equipped);
    expect(badge.label, 'Wearing');
    // First on the shelf: left of, or above, every catalogue picture.
    final first = tester.getTopLeft(google);
    for (final name in ['Bear', 'Cat', 'Fox']) {
      final other = tester.getTopLeft(_tileNamed(name));
      expect(
        other.dy > first.dy + 1 ||
            (other.dy - first.dy).abs() <= 1 && other.dx > first.dx,
        isTrue,
        reason: '$name stands before the Google photo',
      );
    }
    // The shelf menu counts it.
    expect(shelfCount(state, PictureFilter.all), 4);
    expect(shelfCount(state, PictureFilter.chips), 1);
    await _close(tester, state);
  });

  testWidgets(
    'wearing another picture, one tap puts the Google photo back on',
    (tester) async {
      tester.view.physicalSize = const Size(891, 411);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _state(wearing: 2);
      await _openPicker(tester, state);

      final google = _tileNamed('Google photo');
      expect(_badgeOf(tester, google).kind, ShelfBadgeKind.owned);
      expect(_badgeOf(tester, _tileNamed('Cat')).kind, ShelfBadgeKind.equipped);

      final sent = <Map<String, Object?>>[];
      await http.runWithClient(
        () async {
          await tester.tap(google);
          await tester.pump();
        },
        () => MockClient((request) async {
          if (request.url.path == '/api/profile/avatar') {
            sent.add(
              Map<String, Object?>.from(jsonDecode(request.body) as Map),
            );
            return http.Response(jsonEncode({'user': _userJson()}), 200);
          }
          return http.Response('{"profiles":[]}', 200);
        }),
      );
      await tester.pump(const Duration(seconds: 1));

      expect(sent, [
        {'avatar': null},
      ], reason: 'the catalogue picture comes off; the Google photo shows');
      expect(state.user?.activePictureId, isNull);
      expect(state.avatarUrl, _googleUrl);
      expect(
        _badgeOf(tester, _tileNamed('Google photo')).kind,
        ShelfBadgeKind.equipped,
      );
      await _close(tester, state);
    },
  );

  testWidgets('tapping it while it is already worn asks the server nothing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _state();
    await _openPicker(tester, state);
    var asked = 0;
    await http.runWithClient(
      () async {
        await tester.tap(_tileNamed('Google photo'));
        await tester.pump();
      },
      () => MockClient((_) async {
        asked++;
        return http.Response('{}', 200);
      }),
    );
    expect(asked, 0);
    await _close(tester, state);
  });

  test('a guest, and an account whose provider sent no photo, have no such '
      'tile; the priced shelves never show it', () {
    final guest = _state(provider: 'guest');
    expect(providerPictureOf(guest), isNull);
    expect(shelfCount(guest, PictureFilter.all), 3);
    guest.dispose();

    final noPhoto = _state()..user = User.fromJson(_userJson(photo: null));
    expect(providerPictureOf(noPhoto), isNull);
    noPhoto.dispose();

    final google = _state();
    final own = providerPictureOf(google)!;
    expect(own.free, isTrue);
    expect(own.locked, isFalse);
    expect(own.name, 'Google photo');
    for (final f in [
      PictureFilter.chips,
      PictureFilter.hammers,
      PictureFilter.diamonds,
    ]) {
      expect(shelfCount(google, f), google.pictures.where(f.holds).length);
    }
    google.dispose();
  });

  testWidgets('a priced shelf holds no Google photo', (tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _state();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<GameState>.value(value: state),
          ChangeNotifierProvider<FeedbackSettings>.value(
            value: FeedbackSettings(),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(sound: false),
          home: Scaffold(
            body: Builder(
              builder: (context) => SingleChildScrollView(
                child: pictureShelf(
                  context: context,
                  state: state,
                  filter: PictureFilter.chips,
                  radius: 36,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Google photo'), findsNothing);
    expect(find.text('Fox'), findsOneWidget);
    await _close(tester, state);
  });

  testWidgets('its name fits its tile at 640x360, text x1.25, in all five '
      'languages', (tester) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    for (final lang in AppLang.values) {
      final state = _state(lang: lang);
      await _openPicker(tester, state);
      final label = Strings(lang).providerPhoto('google');
      expect(label, isNot('googlePhoto'), reason: '$lang has no entry');
      final text = find.text(label);
      expect(text, findsOneWidget, reason: '$lang');
      final paragraph = tester.renderObject<RenderParagraph>(text);
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: '$lang: "$label" is cut',
      );
      expect(tester.takeException(), isNull, reason: '$lang overflowed');
      await _close(tester, state);
    }
  });
}
