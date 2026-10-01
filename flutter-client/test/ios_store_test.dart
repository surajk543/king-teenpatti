// The iOS app's two doors (owner, 2 Oct 2026: "i want to release app on apple
// store" — Apple purchases and Sign in with Apple).
//
// The App Store: a purchase is a StoreKit 2 transaction whose
// `serverVerificationData` is Apple's signed transaction. It is posted to
// POST /api/purchases/apple as `transaction`, and FINISHED only after the
// server has banked it — the Play rule, in StoreKit's words. An unfinished
// transaction is delivered again at the next session, and StoreKit will not
// sell the same product until it is finished.
//
// Sign in with Apple: offered on iOS only, beside Google; the identity token
// goes to the server as `idToken` under provider `apple`, with the name Apple
// hands the app once.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart'
    show SignInWithAppleButton, SignInWithAppleButtonStyle;
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/net/purchases.dart';
import 'package:teenpatti/net/social_sign_in.dart';
import 'package:teenpatti/screens/login_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';

class _FakeIap implements InAppPurchase {
  bool? autoConsume;
  final completed = <String>[];
  Object? buyThrows;

  @override
  Future<bool> buyConsumable({
    required PurchaseParam purchaseParam,
    bool autoConsume = true,
  }) async {
    this.autoConsume = autoConsume;
    final e = buyThrows;
    if (e != null) throw e;
    return true;
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    completed.add(purchase.purchaseID ?? '');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A StoreKit 2 transaction as the plugin reports it: Apple's transaction id
/// as the purchase id, the signed transaction as the server's data.
PurchaseDetails _transaction(
  String id, {
  String jws = 'header.payload.signature',
  PurchaseStatus status = PurchaseStatus.purchased,
}) => PurchaseDetails(
  purchaseID: id,
  productID: 'chips_a_99',
  verificationData: PurchaseVerificationData(
    localVerificationData: '{}',
    serverVerificationData: jws,
    source: 'app_store',
  ),
  transactionDate: '0',
  status: status,
)..pendingCompletePurchase = status == PurchaseStatus.purchased;

final _product = ProductDetails(
  id: 'chips_a_99',
  title: 'Chips',
  description: '',
  price: '₹99',
  rawPrice: 99,
  currencyCode: 'INR',
);

class _Socket extends GameConnection {
  _Socket() : super('http://127.0.0.1:9');

  final connects = <String>[];

  @override
  void connect(String token) => connects.add(token);

  @override
  void disconnect() {}
}

GameState _state() {
  // Built as on a desktop (no platform plugin is reached), then the platform
  // the test set — an iPhone, an Android phone — is put back.
  final platform = debugDefaultTargetPlatformOverride;
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(
    serverUrl: 'http://127.0.0.1:9',
    connection: _Socket(),
  );
  debugDefaultTargetPlatformOverride = platform;
  return state
    ..lang = AppLang.english
    ..screen = Screen.login;
}

Future<void> _pumpLogin(
  WidgetTester tester,
  GameState state, {
  ThemeData? theme,
}) async {
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
        theme: withScriptFallback(theme ?? AppTheme.dark(sound: false)),
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

  group('the App Store', () {
    test('a purchase is started the way the plugin insists on iOS, and '
        'finished by nobody until the server has banked it', () async {
      final iap = _FakeIap();
      final delivered = <String>[];
      var bank = false;
      final purchases =
          Purchases(iap: iap, available: true, store: Store.appStore)
            ..onDeliver = (p) async {
              delivered.add(p.verificationData.serverVerificationData);
              return bank;
            };
      await purchases.buy(_product);
      // The StoreKit plugin asserts autoConsume on iOS; under StoreKit 2 it
      // finishes nothing.
      expect(iap.autoConsume, isTrue);

      // The server did not bank it (no network): the transaction is left
      // unfinished, for the next session.
      await purchases.handle([_transaction('2000000001')]);
      expect(delivered, ['header.payload.signature']);
      expect(iap.completed, isEmpty);

      // Delivered again and banked: finished, once.
      bank = true;
      await purchases.handle([_transaction('2000000001')]);
      expect(iap.completed, ['2000000001']);

      // StoreKit signs a transaction afresh each time it hands it over: the
      // same purchase under another string is still the one already finished.
      await purchases.handle([_transaction('2000000001', jws: 'h.p.other')]);
      expect(delivered.length, 2);
      expect(iap.completed, ['2000000001']);
    });

    test('unfinished transactions are handed to the server again at the start '
        'of a session', () async {
      final iap = _FakeIap();
      final delivered = <String>[];
      final purchases =
          Purchases(
              iap: iap,
              available: true,
              store: Store.appStore,
              owned: () async => [
                _transaction('2000000002'),
                _transaction('2000000003', status: PurchaseStatus.pending),
              ],
            )
            ..onDeliver = (p) async {
              delivered.add(p.purchaseID!);
              return true;
            };
      await purchases.redeliver();
      expect(delivered, ['2000000002']);
      expect(iap.completed, ['2000000002']);
    });

    test('a pack whose earlier purchase is still unfinished is not shown '
        "StoreKit's refusal: the earlier one is banked and finished", () async {
      final iap = _FakeIap()
        ..buyThrows = PlatformException(
          code: 'storekit_duplicate_product_object',
          message: 'There is a pending transaction for the same product.',
        );
      final failures = <String>[];
      final delivered = <String>[];
      final purchases =
          Purchases(
              iap: iap,
              available: true,
              store: Store.appStore,
              owned: () async => [_transaction('2000000004')],
            )
            ..onFailed = failures.add
            ..onDeliver = (p) async {
              delivered.add(p.purchaseID!);
              return true;
            };
      await purchases.buy(_product);
      await Future<void>.delayed(Duration.zero);
      expect(failures, [Purchases.finishingEarlier]);
      expect(purchases.buying, isFalse);
      expect(delivered, ['2000000004']);
      expect(iap.completed, ['2000000004']);
    });

    test('any other failure to start is said, and nothing counts as open',
        () async {
      final iap = _FakeIap()
        ..buyThrows = PlatformException(
          code: 'storekit2_failed_to_fetch_product',
          message: 'Storekit has failed to fetch this product.',
        );
      final failures = <String>[];
      final purchases =
          Purchases(iap: iap, available: true, store: Store.appStore)
            ..onFailed = failures.add;
      await purchases.buy(_product);
      expect(failures, ['Storekit has failed to fetch this product.']);
      expect(purchases.buying, isFalse);
    });

    test('a server with no door for it yet (404) is no verdict on a receipt',
        () {
      expect(receiptRefusalIsFinal(404), isFalse);
      expect(receiptRefusalIsFinal(400), isTrue);
      expect(receiptRefusalIsFinal(402), isTrue);
    });

    test("each store's receipt is posted to its own door", () async {
      final seen = <(String, Map<String, dynamic>)>[];
      final client = MockClient((request) async {
        seen.add((
          request.url.path,
          jsonDecode(request.body) as Map<String, dynamic>,
        ));
        return http.Response(
          jsonEncode({
            'credited': true,
            'chips': 19200000,
            'diamonds': 0,
            'hammers': 0,
            'missiles': 0,
            'balance': 19700000,
            'user': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final api = ApiClient('http://api.test');
      final apple = await http.runWithClient(
        () => api.redeemPurchase(
          'tok',
          'chips_a_99',
          'h.p.s',
          appStore: true,
        ),
        () => client,
      );
      await http.runWithClient(
        () => api.redeemPurchase('tok', 'chips_a_99', 'play-token'),
        () => client,
      );
      expect(apple.credited, isTrue);
      expect(apple.chips, 19200000);
      expect(seen[0].$1, '/api/purchases/apple');
      expect(seen[0].$2, {'productId': 'chips_a_99', 'transaction': 'h.p.s'});
      expect(seen[1].$1, '/api/purchases/google');
      expect(seen[1].$2, {
        'productId': 'chips_a_99',
        'purchaseToken': 'play-token',
      });
    });

    test('the words for an earlier purchase being finished are in every '
        'language', () {
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        expect(t.purchaseFinishingEarlier, isNot('purchaseFinishingEarlier'));
        expect(t.continueApple, contains('Apple'));
      }
    });
  });

  group('Sign in with Apple', () {
    test("Apple's identity token signs in as provider apple, with the name "
        'Apple handed over', () async {
      final state = _state();
      Map<String, dynamic>? login;
      final client = MockClient((request) async {
        if (request.url.path == '/api/auth/login') {
          login = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'token': 'session-token',
              'isNew': false,
              'welcomeChips': 0,
              'user': {
                'id': 'u-apple',
                'provider': 'apple',
                'displayName': 'Asha Rao',
                'chips': 500000,
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      });
      await http.runWithClient(
        () => state.loginWithProvider(
          'apple',
          () async => 'apple-identity-token',
          nameOf: () => 'Asha Rao',
        ),
        () => client,
      );
      expect(login, {
        'provider': 'apple',
        'idToken': 'apple-identity-token',
        'displayName': 'Asha Rao',
      });
      expect(state.user?.provider, 'apple');
      expect(state.screen, Screen.lobby);
      expect(state.loginError, isNull);
    });

    test('a later sign-in, when Apple hands no name, sends none', () async {
      final state = _state();
      Map<String, dynamic>? login;
      final client = MockClient((request) async {
        if (request.url.path == '/api/auth/login') {
          login = jsonDecode(request.body) as Map<String, dynamic>;
        }
        return http.Response('{"error":"x","message":"x"}', 500);
      });
      await http.runWithClient(
        () => state.loginWithProvider(
          'apple',
          () async => 'apple-identity-token',
          nameOf: () => null,
        ),
        () => client,
      );
      expect(login, {'provider': 'apple', 'idToken': 'apple-identity-token'});
    });

    test('closing Apple\'s sheet is a change of mind, not an error', () async {
      final state = _state();
      var asked = 0;
      await http.runWithClient(
        () => state.loginWithProvider('apple', () async => null),
        () => MockClient((_) async {
          asked++;
          return http.Response('{}', 500);
        }),
      );
      expect(asked, 0);
      expect(state.loginError, isNull);
      expect(state.screen, Screen.login);
    });

    testWidgets('the button stands on the sign-in screen on an iPhone, in '
        "Apple's own face, as tall as Google's", (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.binding.setSurfaceSize(const Size(640, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      expect(SocialSignIn.appleOffered, isTrue);

      final state = _state();
      await _pumpLogin(tester, state);
      final button = find.byKey(const ValueKey('sign-in-apple'));
      expect(button, findsOneWidget);
      final widget = tester.widget<SignInWithAppleButton>(button);
      expect(widget.text, 'Continue with Apple');
      // White on the dark theme, black on the light: Apple's two faces.
      expect(widget.style, SignInWithAppleButtonStyle.white);
      expect(widget.height, 48);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('by day the button is black, and it is said in every '
        'language', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.binding.setSurfaceSize(const Size(640, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final lang in AppLang.values) {
        final state = _state()..lang = lang;
        await _pumpLogin(tester, state, theme: AppTheme.light(sound: false));
        final widget = tester.widget<SignInWithAppleButton>(
          find.byKey(const ValueKey('sign-in-apple')),
        );
        expect(widget.style, SignInWithAppleButtonStyle.black);
        expect(widget.text, Strings(lang).continueApple);
        expect(tester.takeException(), isNull, reason: '$lang');
      }
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('an Android phone is offered guest and Google only', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.binding.setSurfaceSize(const Size(640, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      expect(SocialSignIn.appleOffered, isFalse);
      await _pumpLogin(tester, _state());
      expect(find.byKey(const ValueKey('sign-in-apple')), findsNothing);
      expect(find.text('Continue with Google'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
