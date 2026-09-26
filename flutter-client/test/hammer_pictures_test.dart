// Pictures priced in hammers (owner, 14 Sep 2026): the twenty animated
// rentals cost hammers, Blazing Fire a single one, and the animals stay chips.
//
// The catalogue row, the price on a locked tile, the unlock dialog and its
// singular, the Hammers shelf offered to a player who is short, what a seated
// player may buy, the server's shortage read by the picture's currency, and
// the wallets the picture sheet and the store's Pictures shelf head with —
// laid out on the three screens the game is checked on, in all five
// languages, at the 1.25 text ceiling. A RenderFlex overflow fails a test by
// itself.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/widgets/avatar.dart';
import 'package:teenpatti/widgets/chip_store.dart';
import 'package:teenpatti/widgets/glass_components.dart';
import 'package:teenpatti/widgets/glass_panels.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

Future<void> _loadInter() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
}

ProfilePicture _picture(
  int id,
  String name, {
  String currency = PictureCurrency.hammer,
  int cost = 30,
  String format = 'LOTTIE',
  int days = 100,
}) => ProfilePicture(
  id: id,
  name: name,
  // No address, so a tile draws the initial and nothing is fetched.
  url: '',
  assetFormat: format,
  currency: currency,
  type: 'PREMIUM',
  cost: cost,
  durationDays: days,
  owned: false,
  expiresAt: 0,
);

final _catalogue = [
  _picture(
    1,
    'Bear',
    currency: PictureCurrency.coin,
    cost: 25000,
    format: 'SVG',
    days: 0,
  ),
  _picture(2, 'Toucan Flying'),
  _picture(3, 'Blazing Fire', cost: 1),
  _picture(4, 'Jolly King', currency: PictureCurrency.diamond, cost: 4),
  // No such row is seeded; it stands for a chip-priced picture that would
  // sit on the animated shelf a seated player shops from.
  _picture(5, 'Dancing Chip', currency: PictureCurrency.coin, cost: 25000),
];

Map<String, dynamic> _user({int hammers = 45, int diamonds = 2}) => {
  'id': 'u1',
  'provider': 'guest',
  'displayName': 'Ravi',
  'chips': 200000,
  'diamond': diamonds,
  'hammer': hammers,
  'missile': 1,
};

GameState _state({
  Screen screen = Screen.lobby,
  AppLang lang = AppLang.english,
  int hammers = 45,
  int diamonds = 2,
}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = screen
    ..pictures = _catalogue
    ..user = User.fromJson(_user(hammers: hammers, diamonds: diamonds));
}

void _setScreen(WidgetTester tester, Size size, {double scale = 1.0}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// An empty screen as main.dart builds one — the blur budget and the
/// transparent Scaffold round the Navigator — with [body] on it.
Future<BuildContext> _host(
  WidgetTester tester,
  GameState state,
  FeedbackSettings feedback, {
  Widget Function(BuildContext)? body,
}) async {
  late BuildContext host;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(sound: false),
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
            return body?.call(context) ?? const SizedBox.expand();
          },
        ),
      ),
    ),
  );
  return host;
}

/// A sheet, a dialog or the store, set out.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
}

Future<void> _close(
  WidgetTester tester,
  GameState state,
  FeedbackSettings feedback,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
  state.dispose();
  feedback.dispose();
}

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

void main() {
  setUpAll(_loadInter);

  group('the catalogue row', () {
    Map<String, dynamic> row(Object? currency) => {
      'id': 9,
      'name': 'Cool Cat',
      'url': 'https://example.test/cool-cat.json',
      'assetFormat': 'LOTTIE',
      'currency': ?currency,
      'type': 'PREMIUM',
      'cost': 100,
      'durationDays': 100,
      'owned': false,
      'expiresAt': 0,
    };

    test('carries a hammer price', () {
      final p = ProfilePicture.fromJson(row('HAMMER'));
      expect(p.currency, PictureCurrency.hammer);
      expect(p.pricedInHammers, isTrue);
      expect(p.pricedInDiamonds, isFalse);
      expect(p.cost, 100);
      expect(pictureWalletShelf(p), StoreTab.hammers);
    });

    test(
      'an unknown currency does not break the row and is drawn as chips',
      () {
        final ruby = ProfilePicture.fromJson(row('RUBY'));
        expect(ruby.currency, 'RUBY');
        expect(ruby.pricedInHammers, isFalse);
        expect(ruby.pricedInDiamonds, isFalse);
        expect(pictureWalletShelf(ruby), isNull);
        expect(canAffordPicture(ruby, null), isTrue);
        // Worded as chips, as every row was before the soft currencies.
        expect(
          unlockPictureBody(const Strings(AppLang.english), ruby),
          'Cool Cat costs 100 chips and is yours for 100 days. Unlock it and '
          'wear it now?',
        );
        // No currency at all is chips.
        expect(
          ProfilePicture.fromJson(row(null)).currency,
          PictureCurrency.coin,
        );
      },
    );

    test('is affordable only with the hammers or diamonds it asks for', () {
      final u = User.fromJson(_user(hammers: 29, diamonds: 4));
      final toucan = _picture(2, 'Toucan Flying', cost: 30);
      expect(canAffordPicture(toucan, u), isFalse);
      expect(
        canAffordPicture(toucan, User.fromJson(_user(hammers: 30))),
        isTrue,
      );
      final king = _picture(4, 'Jolly King', currency: 'DIAMOND', cost: 4);
      expect(canAffordPicture(king, u), isTrue);
      expect(
        canAffordPicture(king, User.fromJson(_user(diamonds: 3))),
        isFalse,
      );
      expect(pictureWalletShelf(king), StoreTab.diamonds);
      // Chips are left to the server, as they always were.
      final bear = _catalogue.first;
      expect(canAffordPicture(bear, User.fromJson(_user())), isTrue);
      expect(pictureWalletShelf(bear), isNull);
    });

    test('at a table sells for hammers or diamonds, and not for chips', () {
      for (final (picture, atTable) in [
        for (final p in _catalogue) (p, false),
      ]) {
        expect(pictureSellsHere(picture, atTable: atTable), isTrue);
      }
      expect(pictureSellsHere(_catalogue[1], atTable: true), isTrue);
      expect(pictureSellsHere(_catalogue[3], atTable: true), isTrue);
      expect(pictureSellsHere(_catalogue[0], atTable: true), isFalse);
      expect(pictureSellsHere(_catalogue[4], atTable: true), isFalse);
      // A currency this build does not know is the server's to refuse.
      expect(
        pictureSellsHere(
          _picture(6, 'Ruby Cat', currency: 'RUBY'),
          atTable: true,
        ),
        isTrue,
      );
    });
  });

  group('the unlock sentence', () {
    const t = Strings(AppLang.english);

    test('names hammers, and one hammer in the singular', () {
      expect(
        unlockPictureBody(t, _picture(2, 'Toucan Flying')),
        'Toucan Flying costs 30 hammers and is yours for 100 days. Unlock it '
        'and wear it now?',
      );
      expect(
        unlockPictureBody(t, _picture(3, 'Blazing Fire', cost: 1)),
        'Blazing Fire costs 1 hammer and is yours for 100 days. Unlock it and '
        'wear it now?',
      );
      expect(
        unlockPictureBody(t, _picture(7, 'Cool Cat', cost: 10, days: 0)),
        'Cool Cat costs 10 hammers. Unlock it and wear it now?',
      );
      expect(
        unlockPictureBody(t, _picture(8, 'Paper Plane', cost: 1, days: 0)),
        'Paper Plane costs 1 hammer. Unlock it and wear it now?',
      );
    });

    test('keeps diamonds and chips as they were', () {
      expect(
        unlockPictureBody(t, _catalogue[3]),
        'Jolly King costs 4 diamonds and is yours for 100 days. Unlock it and '
        'wear it now?',
      );
      expect(
        unlockPictureBody(t, _catalogue[0]),
        'Bear costs ${formatChips(25000)} chips. Unlock it and wear it now?',
      );
    });
  });

  group("the server's refusal", () {
    test("is read by the picture's currency, never by its message", () {
      for (final lang in AppLang.values) {
        final state = _state(lang: lang);
        final short = ApiException(
          'Not enough chips for this picture',
          code: 'picture_chips',
          status: 409,
        );
        // Hammers and diamonds: the offer of the shelf, and nothing said.
        expect(state.pictureRefused(2, short), PictureBuyResult.notEnough);
        expect(state.notice, isNull, reason: lang.code);
        expect(state.pictureRefused(4, short), PictureBuyResult.notEnough);
        expect(state.notice, isNull, reason: lang.code);
        // Chips keep the server's sentence.
        expect(state.pictureRefused(1, short), PictureBuyResult.refused);
        expect(state.notice, short.message, reason: lang.code);
        // A picture this phone has not heard of is not guessed at.
        state.notice = null;
        expect(state.pictureRefused(99, short), PictureBuyResult.refused);
        expect(state.notice, short.message, reason: lang.code);
        // A chip-priced picture at a table, in the player's language.
        final seated = ApiException(
          'You can only buy a chip-priced picture in the lobby.',
          code: 'seated',
          status: 409,
        );
        expect(state.pictureRefused(5, seated), PictureBuyResult.refused);
        expect(
          state.notice,
          Strings(lang).pictureChipsLobbyOnly,
          reason: lang.code,
        );
        state.dispose();
      }
    });
  });

  group('a locked picture', () {
    testWidgets('wears the glyph of the wallet that pays, and its price', (
      tester,
    ) async {
      _setScreen(tester, const Size(891, 411));
      final state = _state();
      final feedback = FeedbackSettings();
      await _host(
        tester,
        state,
        feedback,
        body: (context) => SingleChildScrollView(
          child: pictureShelf(
            context: context,
            state: state,
            filter: PictureFilter.all,
            radius: 40,
          ),
        ),
      );
      await tester.pump();

      Finder inTag(String name, Finder matching) => find.descendant(
        of: find.descendant(
          of: find.ancestor(
            of: find.text(name),
            matching: find.byType(PictureChoice),
          ),
          // Public since the table shelf shares it (15 Sep 2026).
          matching: find.byType(PriceTag),
        ),
        matching: matching,
      );

      // The term is the tile's small print under its name (the store polish,
      // 26 Sep 2026): every badge on the shelf is one line, so it left the
      // price tag it used to be a second line of.
      Finder inTile(String name, Finder matching) => find.descendant(
        of: find.ancestor(
          of: find.text(name),
          matching: find.byType(PictureChoice),
        ),
        matching: matching,
      );

      // Hammers: the padlock, the hammer and the count, with the term under
      // the name. Every price carries the padlock since the store polish
      // (26 Sep 2026: "LOCKED / PURCHASABLE: 🔒 Price"); the wallet's glyph
      // stands beside it, so "30" is never read as chips.
      for (final (name, cost) in [
        ('Toucan Flying', '30'),
        ('Blazing Fire', '1'),
      ]) {
        expect(inTag(name, find.byIcon(Icons.lock_rounded)), findsOneWidget);
        expect(inTag(name, find.byIcon(Icons.hardware)), findsOneWidget);
        expect(inTag(name, find.text(cost)), findsOneWidget);
        expect(inTile(name, find.text('100 days')), findsOneWidget);
        expect(inTag(name, find.byIcon(Icons.diamond)), findsNothing);
      }
      // Diamonds keep the gem.
      expect(inTag('Jolly King', find.byIcon(Icons.diamond)), findsOneWidget);
      expect(inTag('Jolly King', find.byIcon(Icons.hardware)), findsNothing);
      // Chips: the padlock and the price, and no wallet glyph.
      expect(inTag('Bear', find.byIcon(Icons.lock_rounded)), findsOneWidget);
      expect(inTag('Bear', find.text(formatChips(25000))), findsOneWidget);
      expect(inTag('Bear', find.byIcon(Icons.hardware)), findsNothing);
      expect(inTag('Bear', find.byIcon(Icons.diamond)), findsNothing);
      expect(tester.takeException(), isNull);

      await _close(tester, state, feedback);
    });
  });

  group('the unlock dialog', () {
    testWidgets('prices a picture in hammers, one hammer in the singular, '
        'with the hammers held under it', (tester) async {
      _setScreen(tester, const Size(891, 411));
      final state = _state(hammers: 45);
      final feedback = FeedbackSettings();
      final host = await _host(tester, state, feedback);
      unawaited(openPicturePicker(host));
      await _settle(tester);

      final dialog = find.byType(GlassDialog);
      await tester.tap(find.text('Toucan Flying'));
      await _settle(tester);
      expect(find.text('Unlock this picture?'), findsOneWidget);
      expect(
        find.text(
          'Toucan Flying costs 30 hammers and is yours for 100 days. Unlock '
          'it and wear it now?',
        ),
        findsOneWidget,
      );
      final held = find.descendant(
        of: dialog,
        matching: find.byType(HammerBalance),
      );
      expect(held, findsOneWidget);
      expect(
        find.descendant(of: held, matching: find.text('45')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.byType(DiamondBalance)),
        findsNothing,
      );
      await tester.tap(find.text('Cancel'));
      await _settle(tester);
      expect(find.text('Unlock this picture?'), findsNothing);

      await tester.tap(find.text('Blazing Fire'));
      await _settle(tester);
      expect(
        find.text(
          'Blazing Fire costs 1 hammer and is yours for 100 days. Unlock it '
          'and wear it now?',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await _settle(tester);

      // A chip-priced one is asked about as before, with no wallet under it.
      await tester.tap(find.text('Bear'));
      await _settle(tester);
      expect(
        find.text(
          'Bear costs ${formatChips(25000)} chips. Unlock it and wear it now?',
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.byType(HammerBalance)),
        findsNothing,
      );
      await tester.tap(find.text('Cancel'));
      await _settle(tester);
      expect(state.buyingPicture, isNull);
      expect(tester.takeException(), isNull);

      await _close(tester, state, feedback);
    });
  });

  group('a player short of hammers', () {
    testWidgets('is offered the Hammers shelf instead of the question', (
      tester,
    ) async {
      _setScreen(tester, const Size(891, 411));
      final state = _state(hammers: 5);
      final feedback = FeedbackSettings();
      final host = await _host(tester, state, feedback);
      unawaited(openPicturePicker(host));
      await _settle(tester);

      await tester.tap(find.text('Toucan Flying'));
      await _settle(tester);
      expect(find.text('Unlock this picture?'), findsNothing);
      expect(find.text('Not enough hammers'), findsOneWidget);
      expect(
        find.text('Toucan Flying costs 30 hammers. Get more hammers?'),
        findsOneWidget,
      );
      // The store's own pill — the FRAMED balance: the picture sheet's panel
      // beneath it holds the same count on a bare HammerBalance since the
      // wallet pairs were built from the pills (24 Sep 2026).
      expect(
        find.descendant(
          of: find.byWidgetPredicate((w) => w is HammerBalance && w.framed),
          matching: find.text('5'),
        ),
        findsOneWidget,
      );
      // The picture they were after is shown in the offer, large and playing,
      // as the unlock question shows it (owner, 14 Sep 2026).
      final shown = tester
          .widgetList<Avatar>(
            find.descendant(
              of: find.byType(GlassDialog),
              matching: find.byType(Avatar),
            ),
          )
          .toList();
      expect(shown, hasLength(1));
      expect(shown.single.fallback, 'Toucan Flying');
      expect(shown.single.animate, isTrue);
      expect(shown.single.radius, greaterThanOrEqualTo(40));
      await tester.tap(find.text('Cancel'));
      await _settle(tester);
      expect(find.text('Not enough hammers'), findsNothing);
      expect(find.text('Hammer Store'), findsNothing);

      // One hammer short of the one-hammer picture: said in the singular.
      state.user = User.fromJson(_user(hammers: 0));
      await tester.tap(find.text('Blazing Fire'));
      await _settle(tester);
      expect(
        find.text('Blazing Fire costs 1 hammer. Get more hammers?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Get hammers'));
      await _settle(tester);
      expect(find.text('Not enough hammers'), findsNothing);
      expect(find.text('Hammer Store'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _close(tester, state, feedback);
    });

    for (final screen in [Screen.lobby, Screen.table]) {
      testWidgets('in the ${screen.name} store, moves the store to its '
          'Hammers shelf', (tester) async {
        _setScreen(tester, const Size(891, 411));
        final state = _state(screen: screen, hammers: 5);
        final feedback = FeedbackSettings();
        final host = await _host(tester, state, feedback);
        unawaited(showChipStore(host, opensOn: StoreTab.pictures));
        await _settle(tester);

        await tester.tap(find.text('Toucan Flying'));
        await _settle(tester);
        expect(find.text('Not enough hammers'), findsOneWidget);
        await tester.tap(find.text('Get hammers'));
        await _settle(tester);
        expect(find.text('Hammer Store'), findsOneWidget);
        // The same store, on another shelf — not a second one over it.
        expect(_private('_ChipStore'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await _close(tester, state, feedback);
      });
    }

    testWidgets("after the server's shortage, is offered the shelf too", (
      tester,
    ) async {
      // The count on this phone said enough; the server knew better. Driven
      // through the refusal the purchase hands the tile, since a test has no
      // session to buy with.
      _setScreen(tester, const Size(891, 411));
      final state = _state(hammers: 45);
      final feedback = FeedbackSettings();
      await _host(tester, state, feedback);
      expect(
        state.pictureRefused(
          2,
          ApiException('Not enough hammers', code: 'picture_chips'),
        ),
        PictureBuyResult.notEnough,
      );
      expect(state.notice, isNull);
      await _close(tester, state, feedback);
    });
  });

  group('the picture menu', () {
    testWidgets('offers All and a Premium shelf per wallet, and filters by '
        'it', (tester) async {
      _setScreen(tester, const Size(891, 411));
      final state = _state()
        ..pictures = [
          ..._catalogue,
          const ProfilePicture(
            id: 6,
            name: 'Cat',
            url: '',
            assetFormat: 'SVG',
            currency: PictureCurrency.coin,
            type: 'FREE',
            cost: 0,
            durationDays: 0,
            owned: true,
            expiresAt: 0,
          ),
        ];
      final feedback = FeedbackSettings();
      final host = await _host(tester, state, feedback);
      unawaited(openPicturePicker(host));
      await _settle(tester);

      // The sheet is headed by the player's name, not "Your picture".
      expect(find.text('Ravi'), findsOneWidget);
      expect(find.text('Your picture'), findsNothing);

      // All, then Premium in chips, hammers and diamonds (owner, 14 Sep
      // 2026) — no Free shelf and no Premium (Animated) one.
      final dropdown = tester.widget<DropdownButton<PictureFilter>>(
        find.byType(DropdownButton<PictureFilter>),
      );
      expect(
        [for (final item in dropdown.items!) item.value],
        [
          PictureFilter.all,
          PictureFilter.chips,
          PictureFilter.hammers,
          PictureFilter.diamonds,
        ],
      );
      expect(
        tester.widget<PictureFilterMenu>(find.byType(PictureFilterMenu)).counts,
        {
          PictureFilter.all: 6,
          PictureFilter.chips: 2,
          PictureFilter.hammers: 2,
          PictureFilter.diamonds: 1,
        },
      );

      Set<String> onShelf() => {
        for (final tile in tester.widgetList<PictureChoice>(
          find.byType(PictureChoice),
        ))
          tile.picture.name,
      };
      Future<void> pick(PictureFilter shelf) async {
        tester
            .widget<PictureFilterMenu>(find.byType(PictureFilterMenu))
            .onChanged(shelf);
        await _settle(tester);
      }

      expect(onShelf(), {
        'Bear',
        'Toucan Flying',
        'Blazing Fire',
        'Jolly King',
        'Dancing Chip',
        'Cat',
      });
      await pick(PictureFilter.chips);
      expect(onShelf(), {'Bear', 'Dancing Chip'});
      await pick(PictureFilter.hammers);
      expect(onShelf(), {'Toucan Flying', 'Blazing Fire'});

      // The order menu on the right (owner, 14 Sep 2026): price low to high
      // by default, high to low on request, on whichever shelf is showing.
      List<String> inOrder() => [
        for (final tile in tester.widgetList<PictureChoice>(
          find.byType(PictureChoice),
        ))
          tile.picture.name,
      ];
      final hammers = state.pictures.where(PictureFilter.hammers.holds).toList()
        ..sort((a, b) => a.cost.compareTo(b.cost));
      expect(
        tester.widget<PictureSortMenu>(find.byType(PictureSortMenu)).value,
        PictureSort.lowToHigh,
      );
      expect(inOrder(), [for (final p in hammers) p.name]);
      tester
          .widget<PictureSortMenu>(find.byType(PictureSortMenu))
          .onChanged(PictureSort.highToLow);
      await _settle(tester);
      expect(
        tester.widget<PictureSortMenu>(find.byType(PictureSortMenu)).value,
        PictureSort.highToLow,
      );
      expect(inOrder(), [for (final p in hammers.reversed) p.name]);
      await pick(PictureFilter.diamonds);
      expect(onShelf(), {'Jolly King'});
      expect(tester.takeException(), isNull);

      await _close(tester, state, feedback);
    });

    testWidgets('closes cleanly after its pictures were put in another order', (
      tester,
    ) async {
      _setScreen(tester, const Size(891, 411));
      final state = _state();
      final feedback = FeedbackSettings();
      final host = await _host(tester, state, feedback);
      unawaited(openPicturePicker(host));
      await _settle(tester);

      // Dearest first, on the All shelf, then the sheet is closed as Back
      // closes it: the tiles have swapped pictures in place before the sheet
      // goes (14 Sep 2026, a red screen on both emulators).
      tester
          .widget<PictureSortMenu>(find.byType(PictureSortMenu))
          .onChanged(PictureSort.highToLow);
      await _settle(tester);
      Navigator.of(host).pop();
      // The sheet is still animating out when the picker has already disposed
      // its notifiers, and the lobby's one-second tick rebuilds it then: a
      // grid that re-subscribed on that rebuild used a disposed notifier.
      await tester.pump();
      state.say('tick');
      await tester.pump(const Duration(milliseconds: 50));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(PictureSortMenu), findsNothing);

      await _close(tester, state, feedback);
    });

    testWidgets('draws its pill in the theme it is in, day or night', (
      tester,
    ) async {
      _setScreen(tester, const Size(891, 411));
      final state = _state();
      final feedback = FeedbackSettings();

      // The pill's fill and the ink of its "All" label, in [theme].
      Future<(Color, Color)> paint(ThemeData theme) async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<GameState>.value(value: state),
              ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
            ],
            child: MaterialApp(
              theme: theme,
              home: Scaffold(
                body: Center(
                  child: PictureFilterMenu(
                    value: PictureFilter.all,
                    counts: const {},
                    onChanged: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        // MaterialApp cross-fades one theme into the next; measure after it.
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        final pill = tester.widget<Container>(
          find
              .descendant(
                of: find.byType(PictureFilterMenu),
                matching: find.byType(Container),
              )
              .first,
        );
        final all = tester.widget<Text>(find.text('All'));
        return ((pill.decoration! as BoxDecoration).color!, all.style!.color!);
      }

      // It was the same dark pill in both themes (owner, 14 Sep 2026).
      final (nightPill, nightInk) = await paint(AppTheme.dark(sound: false));
      final (dayPill, dayInk) = await paint(AppTheme.light(sound: false));
      expect(nightPill.computeLuminance(), lessThan(0.1));
      expect(nightInk.computeLuminance(), greaterThan(0.6));
      expect(dayPill.computeLuminance(), greaterThan(0.6));
      expect(dayInk.computeLuminance(), lessThan(0.1));
      expect(tester.takeException(), isNull);

      await _close(tester, state, feedback);
    });

    testWidgets('draws a locked picture at full colour', (tester) async {
      _setScreen(tester, const Size(891, 411));
      final state = _state();
      final feedback = FeedbackSettings();
      final host = await _host(tester, state, feedback);
      unawaited(openPicturePicker(host));
      await _settle(tester);

      final tiles = find.byType(PictureChoice);
      expect(tiles, findsNWidgets(_catalogue.length));
      final faded = tester
          .widgetList<Opacity>(
            find.descendant(of: tiles, matching: find.byType(Opacity)),
          )
          .where((o) => o.opacity < 1);
      expect(faded, isEmpty);

      await _close(tester, state, feedback);
    });
  });

  group('at a table', () {
    testWidgets('a hammer picture is for sale and a chip-priced one is not', (
      tester,
    ) async {
      _setScreen(tester, const Size(891, 411));
      final state = _state(screen: Screen.table, hammers: 45);
      final feedback = FeedbackSettings();
      final host = await _host(tester, state, feedback);
      unawaited(showChipStore(host, opensOn: StoreTab.pictures));
      await _settle(tester);
      // The animated shelf alone, and its blurb says what it costs.
      expect(
        find.text('Unlock an animated picture with hammers or diamonds.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Dancing Chip'));
      await _settle(tester);
      expect(find.text('Unlock this picture?'), findsNothing);
      expect(
        state.notice,
        'You can only buy a chip-priced picture in the lobby.',
      );

      state.notice = null;
      await tester.tap(find.text('Toucan Flying'));
      await _settle(tester);
      expect(find.text('Unlock this picture?'), findsOneWidget);
      expect(state.notice, isNull);
      await tester.tap(find.text('Cancel'));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      await _close(tester, state, feedback);
    });
  });

  group('the wallets over the pictures', () {
    const screens = [Size(640, 360), Size(891, 411), Size(1280, 800)];
    for (final size in screens) {
      final name = '${size.width.toInt()}x${size.height.toInt()}';
      for (final lang in AppLang.values) {
        testWidgets('at $name in ${lang.englishName}, the picture sheet heads '
            'with diamonds and hammers, and its hammer dialog fits', (
          tester,
        ) async {
          _setScreen(tester, size, scale: 1.25);
          final t = Strings(lang);
          final state = _state(lang: lang, hammers: 250, diamonds: 100);
          final feedback = FeedbackSettings();
          final host = await _host(tester, state, feedback);
          unawaited(openPicturePicker(host));
          await _settle(tester);

          final wallets = find.byType(PictureWalletBalances);
          expect(wallets, findsOneWidget);
          expect(
            find.descendant(of: wallets, matching: find.text('100')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: wallets, matching: find.text('250')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: wallets, matching: find.byIcon(Icons.hardware)),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);

          await tester.tap(find.text('Toucan Flying'));
          await _settle(tester);
          expect(
            find.text(t.unlockRentBodyHammers('Toucan Flying', 30, 100)),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.text(t.cancel));
          await _settle(tester);

          await _close(tester, state, feedback);
        });
      }
    }

    for (final (size, scale, stacked) in const [
      (Size(1280, 800), 1.0, false),
      // One over the other at 891x411 since the seventh shelf (Emojis, owner
      // 26 Sep 2026) took a key's width from the header: beside the row the
      // widest blurb no longer keeps its one line there.
      (Size(891, 411), 1.0, true),
      (Size(640, 360), 1.25, true),
    ]) {
      final name = '${size.width.toInt()}x${size.height.toInt()}';
      testWidgets('on the store\'s Pictures shelf at $name, text x$scale, '
          'they stand ${stacked ? 'one over the other' : 'in a row'} and '
          'the blurb keeps its words', (tester) async {
        _setScreen(tester, size, scale: scale);
        for (final screen in [Screen.lobby, Screen.table]) {
          final state = _state(screen: screen, hammers: 250, diamonds: 100);
          final feedback = FeedbackSettings();
          final host = await _host(tester, state, feedback);
          unawaited(showChipStore(host, opensOn: StoreTab.pictures));
          await _settle(tester);

          final wallets = find.byType(PictureWalletBalances);
          expect(wallets, findsOneWidget);
          expect(
            tester.widget<PictureWalletBalances>(wallets).stacked,
            stacked,
            reason: screen.name,
          );
          expect(
            find.descendant(of: wallets, matching: find.text('250')),
            findsOneWidget,
          );
          final blurb = screen == Screen.table
              ? 'Unlock an animated picture with hammers or diamonds.'
              : 'Unlock a picture with chips, hammers or diamonds.';
          expect(
            tester
                .renderObject<RenderParagraph>(find.text(blurb))
                .didExceedMaxLines,
            isFalse,
            reason: screen.name,
          );
          expect(tester.takeException(), isNull);

          await _close(tester, state, feedback);
        }
      });
    }
  });

  group('the picture sheet header', () {
    testWidgets('carries a day/night switch that flips the theme', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      _setScreen(tester, const Size(640, 360));
      final state = _state();
      final feedback = FeedbackSettings();
      final host = await _host(tester, state, feedback);
      unawaited(openPicturePicker(host));
      await _settle(tester);

      final dayNight = find.byType(DayNightSwitch);
      expect(dayNight, findsOneWidget);
      final before = state.themeMode;
      await tester.tap(
        find.descendant(of: dayNight, matching: find.byType(Switch)),
      );
      await _settle(tester);
      expect(state.themeMode, isNot(before));
      expect(state.themeMode, anyOf(ThemeMode.dark, ThemeMode.light));
      expect(tester.takeException(), isNull);

      await _close(tester, state, feedback);
    });
  });
}
