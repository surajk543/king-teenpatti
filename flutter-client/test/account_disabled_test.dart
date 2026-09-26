// A disabled account (users.is_active FALSE; owner, 26 Sep 2026: "when user
// login in UI, if is_active is false, then show a pop up that your account is
// disabled, please connect with support … he cannot join the table also").
// The server answers account_disabled at every door; the app turns that code,
// wherever it arrives, into one popup on the sign-in screen.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/config/server_config.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/screens/login_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';

/// The server's refusal, exactly as every door writes it.
http.Response _disabled() => http.Response(
  jsonEncode({
    'error': 'account_disabled',
    'message': 'Your account is disabled. Please contact support.',
  }),
  403,
  headers: {'content-type': 'application/json'},
);

GameState _state() {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://api.test');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = AppLang.english
    ..screen = Screen.login;
}

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

  test('the client hears account_disabled from any answer before it throws',
      () async {
    var heard = 0;
    final api = ApiClient('http://api.test')..onAccountDisabled = () => heard++;
    final error = await http.runWithClient(
      () => api.me('tok').then<Object?>((_) => null, onError: (Object e) => e),
      () => MockClient((_) async => _disabled()),
    );
    expect(heard, 1);
    expect(error, isA<ApiException>());
    expect((error as ApiException).code, accountDisabledCode);
    expect(error.status, 403);

    // Any other refusal is not a disabled account.
    await http.runWithClient(
      () => api.me('tok').then<Object?>((_) => null, onError: (Object e) => e),
      () => MockClient(
        (_) async => http.Response(
          jsonEncode({'error': 'invalid_session', 'message': 'x'}),
          401,
        ),
      ),
    );
    expect(heard, 1);
  });

  test('a refused guest sign-in raises the popup and writes no error line',
      () async {
    final state = _state();
    addTearDown(state.dispose);
    await http.runWithClient(
      () => state.loginAsGuest('Ravi'),
      () => MockClient((_) async => _disabled()),
    );
    expect(state.accountDisabled, isTrue);
    expect(state.loginError, isNull);
    expect(state.user, isNull);
    expect(state.screen, Screen.login);

    state.dismissAccountDisabled();
    expect(state.accountDisabled, isFalse);

    // Any other refusal still says itself on the line.
    await http.runWithClient(
      () => state.loginAsGuest('Ravi'),
      () => MockClient(
        (_) async => http.Response(
          jsonEncode({'error': 'invalid_device_id', 'message': 'Bad device'}),
          400,
        ),
      ),
    );
    expect(state.accountDisabled, isFalse);
    expect(state.loginError, 'Bad device');
  });

  testWidgets('the popup names the state, the support address, and closes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _state()..accountDisabled = true;
    await _pumpLogin(tester, state);

    expect(find.byType(AccountDisabledDialog), findsOneWidget);
    expect(find.text('Account disabled'), findsOneWidget);
    expect(
      find.text('Your account is disabled. Please contact support.'),
      findsOneWidget,
    );
    expect(find.text(ServerConfig.supportEmail), findsOneWidget);

    // The one-second tick rebuilds the screen; it never raises a second one.
    state.notifyListeners();
    await tester.pump();
    expect(find.byType(AccountDisabledDialog), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('account-disabled-close')));
    await tester.pumpAndSettle();
    expect(find.byType(AccountDisabledDialog), findsNothing);
    expect(state.accountDisabled, isFalse);

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
        ..accountDisabled = true;
      await _pumpLogin(tester, state);
      final t = Strings(lang);
      expect(find.text(t.accountDisabledTitle), findsOneWidget, reason: '$lang');
      expect(find.text(t.accountDisabledBody), findsOneWidget, reason: '$lang');
      expect(tester.takeException(), isNull, reason: '$lang overflowed');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      state.dispose();
    }
  });
}
