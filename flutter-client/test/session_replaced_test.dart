// One signed-in device per account (owner, 28 Sep 2026: "when someone is
// already logged in with google account in one device and some other guy
// tries to login with same google account in diff device, the first one will
// be auto logout and showing message someone has logged in your account").
// The server answers session_replaced wherever the replaced device knocks — a
// REST 401, the socket's handshake, and the `session:replaced` push that ends
// its live connection. The app turns every one of them into the same thing:
// signed out, the token gone (so it never reconnects and takes the seat back),
// and one popup on the sign-in screen that says why.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/main.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/screens/login_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';
import 'table_scenes.dart';

/// The server's refusal, exactly as RequireAuth writes it, answering
/// [request] (a real client hands every response its request, which is how
/// the app knows which token was refused; MockClient leaves that to us).
http.Response _replaced(http.Request request) => http.Response(
  jsonEncode({
    'error': 'session_replaced',
    'message': 'Your account has been signed in on another device.',
  }),
  401,
  headers: {'content-type': 'application/json'},
  request: request,
);

/// A socket that records what the app asks of it and lets the test speak
/// for the server.
class _Socket extends GameConnection {
  _Socket() : super('http://127.0.0.1:9');

  final errors = StreamController<({String? code, String message})>.broadcast();
  final connects = <String>[];
  int disconnects = 0;

  @override
  Stream<({String? code, String message})> get onError => errors.stream;

  @override
  void connect(String token) => connects.add(token);

  @override
  void disconnect() => disconnects++;
}

GameState _state({GameConnection? connection}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(
    serverUrl: 'http://127.0.0.1:9',
    connection: connection,
  );
  debugDefaultTargetPlatformOverride = null;
  return state..lang = AppLang.english;
}

User _user() => User.fromJson(_userJson);

const _userJson = {
  'id': 'u0',
  'provider': 'google',
  'displayName': 'Suraj Kumar',
  'chips': 245000,
};

/// Answers every request the app makes on its own at start with a harmless
/// 404, and the one the test is about with [answer].
MockClient _server(Future<http.Response> Function(http.Request) answer) =>
    MockClient((request) async {
      if (request.url.path == '/api/auth/me') return answer(request);
      return http.Response('{"error":"not_found"}', 404);
    });

Future<void> _pumpLogin(WidgetTester tester, GameState state) async {
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
        builder: (context, child) => GlassBudget(child: child!),
        home: const LoginScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(loadScriptFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the client hears session_replaced from any answer, with the token '
      'the refused request carried', () async {
    final heard = <String?>[];
    final api = ApiClient('http://api.test')..onSessionReplaced = heard.add;
    final error = await http.runWithClient(
      () => api
          .me('old-token')
          .then<Object?>((_) => null, onError: (Object e) => e),
      () => MockClient((request) async => _replaced(request)),
    );
    expect(heard, ['old-token']);
    expect(error, isA<ApiException>());
    expect((error as ApiException).code, sessionReplacedCode);
    expect(error.status, 401);

    // Any other refusal is not a replaced sign-in.
    await http.runWithClient(
      () => api.me('tok').then<Object?>((_) => null, onError: (Object e) => e),
      () => MockClient(
        (_) async => http.Response(
          jsonEncode({'error': 'invalid_session', 'message': 'x'}),
          401,
        ),
      ),
    );
    expect(heard, ['old-token']);
  });

  test('at the table, the server saying so signs the device out: the token '
      'goes, the socket is let go and never reconnected, and the sign-in '
      'screen owes the popup', () async {
    SharedPreferences.setMockInitialValues({'token': 'phone-a-token'});
    final socket = _Socket();
    final state = _state(connection: socket);
    addTearDown(state.dispose);
    await http.runWithClient(
      state.start,
      () => _server(
        (_) async => http.Response(jsonEncode({'user': _userJson}), 200),
      ),
    );
    expect(state.screen, Screen.lobby);
    expect(socket.connects, ['phone-a-token']);
    state
      ..screen = Screen.table
      ..handleState(opponentTurnRoom());
    expect(state.room, isNotNull);
    state.notice = null;

    // The other device signed in: the server pushes session:replaced and
    // ends this connection.
    socket.errors.add((
      code: sessionReplacedCode,
      message: sessionReplacedCode,
    ));
    await pumpEventQueue();

    expect(state.sessionReplaced, isTrue);
    expect(state.screen, Screen.login);
    expect(state.user, isNull);
    expect(state.room, isNull);
    expect(state.notice, isNull, reason: 'the popup says it, not a toast');
    expect(socket.disconnects, greaterThan(0));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('token'), isNull);
    // Nothing connects the replaced token again, whatever else happens.
    state.handleLifecycle(AppLifecycleState.paused);
    state.handleLifecycle(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(socket.connects, ['phone-a-token']);

    state.dismissSessionReplaced();
    expect(state.sessionReplaced, isFalse);
  });

  test('a cold start whose saved session was replaced falls to the sign-in '
      'screen with the popup owed', () async {
    SharedPreferences.setMockInitialValues({'token': 'phone-a-token'});
    final socket = _Socket();
    final state = _state(connection: socket);
    addTearDown(state.dispose);
    await http.runWithClient(
      state.start,
      () => _server((request) async => _replaced(request)),
    );
    expect(state.sessionReplaced, isTrue);
    expect(state.screen, Screen.login);
    expect(socket.connects, isEmpty, reason: 'never connected on that token');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('token'), isNull);
  });

  test('a late 401 about a token this phone has already signed in past is '
      'not about this session', () async {
    final socket = _Socket();
    final state = _state(connection: socket);
    addTearDown(state.dispose);
    await http.runWithClient(
      state.start,
      () => _server((request) async => _replaced(request)),
    );
    state
      ..debugToken = 'old-token'
      ..user = _user()
      ..screen = Screen.lobby;

    // A read sent with the old token lands after this phone signed in again.
    await http.runWithClient(
      state.refreshUser,
      () => _server((request) async {
        state.debugToken = 'new-token';
        return _replaced(request);
      }),
    );
    expect(state.sessionReplaced, isFalse);
    expect(state.screen, Screen.lobby);
    expect(state.user, isNotNull);
  });

  test('with nobody signed in, a stray word about a replaced session is '
      'nothing', () async {
    final socket = _Socket();
    final state = _state(connection: socket);
    addTearDown(state.dispose);
    await http.runWithClient(
      state.start,
      () => _server((request) async => _replaced(request)),
    );
    expect(state.screen, Screen.login);
    socket.errors.add((
      code: sessionReplacedCode,
      message: sessionReplacedCode,
    ));
    await pumpEventQueue();
    expect(state.sessionReplaced, isFalse);
  });

  testWidgets('signed out from under an open sheet, the sheet goes and the '
      'popup stands on the sign-in screen alone', (tester) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _state()
      ..screen = Screen.lobby
      ..debugToken = 'phone-a-token'
      ..user = _user()
      ..pictures = const [
        ProfilePicture(
          id: 1,
          name: 'Bear',
          url: '',
          assetFormat: 'SVG',
          type: 'FREE',
          cost: 0,
          durationDays: 0,
          owned: true,
          expiresAt: 0,
        ),
      ];
    final feedback = FeedbackSettings();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<GameState>.value(value: state),
          ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
        ],
        child: const KingTeenPattiApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    openPicturePicker(tester.element(find.byType(LobbyScreen)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(PictureChoice), findsWidgets, reason: 'the sheet is up');

    // The account signs in on another device.
    state.sessionReplaced = true;
    await state.signOut();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(
      find.byType(PictureChoice),
      findsNothing,
      reason: 'the sheet is gone',
    );
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(SessionReplacedDialog), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    state.dispose();
    feedback.dispose();
  });

  testWidgets('the popup says the account signed in elsewhere, and closes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _state()
      ..screen = Screen.login
      ..sessionReplaced = true;
    await _pumpLogin(tester, state);

    expect(find.byType(SessionReplacedDialog), findsOneWidget);
    expect(find.text('Signed in on another device'), findsOneWidget);
    expect(
      find.textContaining(
        'Someone has signed in to your account on another '
        'device, so you have been signed out here.',
      ),
      findsOneWidget,
    );

    // The one-second tick rebuilds the screen; it never raises a second one.
    state.notifyListeners();
    await tester.pump();
    expect(find.byType(SessionReplacedDialog), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('session-replaced-close')));
    await tester.pumpAndSettle();
    expect(find.byType(SessionReplacedDialog), findsNothing);
    expect(state.sessionReplaced, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('it fits a 640x360 phone at text x1.25 in all five languages', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    for (final lang in AppLang.values) {
      final state = _state()
        ..lang = lang
        ..screen = Screen.login
        ..sessionReplaced = true;
      await _pumpLogin(tester, state);
      final t = Strings(lang);
      expect(t.sessionReplacedTitle, isNot('sessionReplacedTitle'));
      expect(t.sessionReplacedBody, isNot('sessionReplacedBody'));
      expect(
        find.text(t.sessionReplacedTitle),
        findsOneWidget,
        reason: '$lang',
      );
      expect(find.text(t.sessionReplacedBody), findsOneWidget, reason: '$lang');
      expect(tester.takeException(), isNull, reason: '$lang overflowed');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      state.dispose();
    }
  });
}
