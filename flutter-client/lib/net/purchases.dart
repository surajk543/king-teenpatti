import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart'
    show BillingResponse;
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart'
    show SK2PurchaseDetails;
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart'
    show SK2Transaction;

/// Which store this build buys from. It decides where a receipt is posted
/// (`/api/purchases/google` or `/api/purchases/apple`) and how a purchase is
/// finished; the products and their ids are the same in both.
enum Store {
  /// Google Play (Android).
  play,

  /// The App Store (iOS), through StoreKit 2.
  appStore,

  /// Neither — a desktop or test run. Nothing can be bought.
  none,
}

/// The store side of the chip store: Google Play on Android and, since
/// 2 Oct 2026 (owner: "i want to release app on apple store"), the App Store
/// on iOS. What follows was written about Play and holds for both — where the
/// App Store differs, [Store.appStore] says how.
///
/// This class knows how to start a purchase and how to hear about one
/// finishing. It knows nothing about how many chips a pack is worth — the
/// server holds that, and is the only thing that decides it.
///
/// # Why the stream matters more than the button
///
/// A purchase does not finish when the player taps Buy. Play may take seconds
/// or days: a card needs 3-D Secure, a parent has to approve, the network
/// drops, the app is killed mid-flow. Play remembers, and delivers the
/// purchase to `purchaseStream` whenever it can — including on a launch long
/// afterwards, on a new device, or after a reinstall. So the stream is
/// subscribed at startup and not when the store is opened; a purchase that
/// arrives while the store is closed still has to be honoured.
///
/// # Why the purchase is consumed last
///
/// A purchase is only finished with Play — CONSUMED, since a chip pack must be
/// buyable again — after OUR server has banked what it bought. Until then Play
/// holds it as owned, and [redeliver] hands every owned purchase to the server
/// again at the start of each session (app start, sign-in, reconnect): if the
/// app dies, or the network drops, between paying and crediting, the next
/// session credits it. Consuming first would throw the receipt away and the
/// player would have paid for nothing.
///
/// That is why [buy] passes `autoConsume: false`. The plugin's default
/// consumes a consumable the moment Play reports it — before the purchase
/// even reaches [purchaseStream], let alone the server — and a consumed
/// purchase is never delivered again, by Play or by a query, so a credit
/// that failed on the network was lost for good (24 Sep 2026, owner's "fix
/// all bugs"; release review RC-03). Play itself never re-delivers an owned
/// consumable on launch, which is why [redeliver] asks for them.
///
/// The server is idempotent on the purchase token (its ledger row's action_id
/// is `gplay:<token>`, a diamond or hammer pack's guard row is keyed on it),
/// so the repeat deliveries this design invites cannot double-credit; the
/// server also acknowledges the purchase when it credits it, so a purchase
/// whose consume has not happened yet is not refunded by Play after 3 days.
///
/// # The App Store
///
/// The same order with StoreKit 2's words. A purchase arrives on the stream
/// as a TRANSACTION whose `serverVerificationData` is Apple's signed
/// transaction (a JWS); the server verifies the signature itself and banks it
/// under Apple's transaction id (`appstore:<id>`), and only then is the
/// transaction FINISHED (`completePurchase`). The plugin insists on
/// `autoConsume: true` on iOS, but under StoreKit 2 that finishes nothing —
/// finishing is always this class's call. An unfinished transaction is what
/// Play's "owned" purchase is: [redeliver] asks StoreKit for them
/// (`Transaction.unfinished`) at every session start. StoreKit refuses to
/// sell a product whose last transaction is still unfinished, so [buy]
/// answers [finishingEarlier] and redelivers instead of showing its error.
class Purchases {
  /// What [onFailed] carries when Play gives no reason of its own — its
  /// billing flow did not launch, or it reported an error with no message.
  /// GameState shows it in the player's language (Strings.purchaseNotLaunched).
  static const notLaunched = 'The purchase did not go through.';

  /// What [onFailed] carries when StoreKit will not sell a product because
  /// an earlier purchase of it has not been banked and finished yet — which
  /// [buy] then sets about doing. GameState shows it in the player's language
  /// (Strings.purchaseFinishingEarlier).
  static const finishingEarlier = 'Finishing an earlier purchase.';

  Purchases({
    InAppPurchase? iap,
    @visibleForTesting Future<bool> Function(PurchaseDetails purchase)? consume,
    @visibleForTesting Future<List<PurchaseDetails>> Function()? owned,
    @visibleForTesting this._available = false,
    @visibleForTesting Store? store,
  }) : _iapOverride = iap,
       _storeOverride = store,
       _consumeOverride = consume,
       _ownedOverride = owned;

  final InAppPurchase? _iapOverride;
  final Store? _storeOverride;

  /// The store this device buys from.
  Store get store =>
      _storeOverride ??
      (Platform.isIOS
          ? Store.appStore
          : Platform.isAndroid
          ? Store.play
          : Store.none);

  /// Resolved on first use, not at construction: `InAppPurchase.instance`
  /// registers the platform plugin, which a widget test must never reach.
  InAppPurchase get _iap => _iapOverride ?? InAppPurchase.instance;

  final Future<bool> Function(PurchaseDetails purchase)? _consumeOverride;
  final Future<List<PurchaseDetails>> Function()? _ownedOverride;
  StreamSubscription<List<PurchaseDetails>>? _sub;

  /// [start]'s work, so [redeliver] can wait for Play to be reachable first.
  Future<void>? _starting;

  /// Purchase tokens being handed to the server right now, so a purchase the
  /// stream and a [redeliver] bring at the same moment is posted once.
  final Set<String> _delivering = {};

  /// Purchase tokens finished (consumed) in this run: a query answered before
  /// the consume landed must not post them again.
  final Set<String> _finished = {};

  /// Called for every purchase that reaches the "deliver it" stage. Must
  /// return true once the chips are safely credited; only then is the
  /// purchase completed with Play.
  Future<bool> Function(PurchaseDetails purchase)? onDeliver;

  /// Called when a purchase fails or is cancelled, with a message fit to show.
  void Function(String message)? onFailed;

  /// Called when a purchase is waiting on the player or their bank, so the UI
  /// can say "waiting for confirmation" rather than looking broken.
  void Function()? onPending;

  bool _available;

  /// Whether this device can buy at all. False on an emulator without Play
  /// Services, on a build side-loaded outside Play, on an iPhone where
  /// purchases are restricted, anywhere the store is unavailable — none of
  /// which are errors, so the store should say so plainly rather than fail
  /// when the button is pressed.
  bool get available => _available;

  /// Subscribes to the store. Safe to call once at startup; further calls
  /// are ignored. Nothing on a platform with no store ([Store.none]).
  ///
  /// iOS was held back here until the server had a door for Apple's receipt:
  /// a StoreKit transaction posted to `/api/purchases/google` is refused, and
  /// a refused purchase is finished — the player would have paid Apple and
  /// been given nothing. `POST /api/purchases/apple` is that door (2 Oct
  /// 2026), and GameState posts each store's receipt to its own.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    if (store == Store.none) return;
    try {
      _available = await _iap.isAvailable();
    } catch (_) {
      _available = false;
    }
    if (!_available) return;
    _sub = _iap.purchaseStream.listen(
      handle,
      onError: (Object e) => onFailed?.call('$e'),
    );
  }

  /// Hands every purchase Play still holds as OWNED — bought, but not yet
  /// consumed, which here means not yet banked by the server — to [onDeliver]
  /// again, and consumes each one the server banks.
  ///
  /// Called at the start of every session (GameState's `session:ready`), so a
  /// credit that failed on the network, or a purchase that completed while
  /// the app was closed or signed out, is credited the next time the player
  /// is connected. A purchase still PENDING with the bank is left alone: it
  /// is not paid yet, and Play reports it on the stream once it is.
  Future<void> redeliver() async {
    await _starting;
    if (!_available) return;
    final List<PurchaseDetails> owned;
    try {
      owned = await (_ownedOverride?.call() ?? _queryOwned());
    } catch (_) {
      return; // Play unreachable just now: the next session asks again.
    }
    await handle([
      for (final p in owned)
        if (p.status == PurchaseStatus.purchased ||
            p.status == PurchaseStatus.restored)
          p,
    ]);
  }

  /// Play's own list of owned purchases. `restorePurchases()` is NOT used:
  /// it marks every purchase `restored`, a still-pending one included, and
  /// throws away the whole list when the subscriptions half of its query
  /// fails.
  ///
  /// On the App Store "owned" is every UNFINISHED transaction — bought, and
  /// not yet banked — each with Apple's signed transaction to post.
  Future<List<PurchaseDetails>> _queryOwned() async {
    if (store == Store.appStore) {
      final unfinished = await SK2Transaction.unfinishedTransactions();
      return [
        for (final tx in unfinished)
          SK2PurchaseDetails(
            productID: tx.productId,
            purchaseID: tx.id,
            verificationData: PurchaseVerificationData(
              localVerificationData: tx.jsonRepresentation ?? '',
              serverVerificationData: tx.receiptData ?? '',
              source: 'app_store',
            ),
            transactionDate: tx.purchaseDate,
            status: PurchaseStatus.purchased,
            appAccountToken: tx.appAccountToken,
          ),
      ];
    }
    final android = _iap
        .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
    final res = await android.queryPastPurchases();
    return res.pastPurchases;
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// Looks up what Play will actually charge, so the store can show the
  /// player's own currency rather than a hardcoded rupee figure.
  ///
  /// Returns an empty map when Play is unavailable or knows none of the ids —
  /// the caller falls back to the list price, which is better than an empty
  /// shelf.
  Future<Map<String, ProductDetails>> priceList(Set<String> productIds) async {
    if (!_available) return const {};
    try {
      final res = await _iap.queryProductDetails(productIds);
      return {for (final p in res.productDetails) p.id: p};
    } catch (_) {
      return const {};
    }
  }

  /// Starts a purchase. The result arrives on the stream, not here.
  ///
  /// Chips are CONSUMABLE: a pack must be buyable again, so the purchase is
  /// consumed after delivery rather than held as an entitlement — by
  /// [handle], once the server has banked it, never by the plugin on arrival
  /// (`autoConsume: false`; see the class doc).
  Future<void> buy(ProductDetails product) async {
    if (!_available) {
      onFailed?.call(
        store == Store.appStore
            ? 'The App Store is not available on this device.'
            : 'Google Play is not available on this device.',
      );
      return;
    }
    final param = PurchaseParam(productDetails: product);
    _buyStartedAt = DateTime.now();
    try {
      // False, without a throw, when Play's billing flow did not launch: no
      // sheet opened and nothing will arrive on the stream, so the sheet must
      // not count as open ([buying]) — a seated phone put away would keep
      // its socket for [buyingFor] and be shown out with no way back.
      final launched = await _iap.buyConsumable(
        purchaseParam: param,
        // The plugin asserts true on iOS; under StoreKit 2 it finishes
        // nothing — [handle] still finishes after the server has banked.
        autoConsume: store == Store.appStore,
      );
      if (!launched) {
        _buyStartedAt = null;
        onFailed?.call(notLaunched);
      }
    } on PlatformException catch (e) {
      _buyStartedAt = null;
      if (e.code == 'storekit_duplicate_product_object') {
        // An earlier purchase of this product is still unfinished: paid, and
        // not banked yet. Bank and finish it now rather than show StoreKit's
        // refusal; the player can then buy again.
        onFailed?.call(finishingEarlier);
        unawaited(redeliver());
      } else {
        onFailed?.call(e.message ?? '$e');
      }
    } catch (e) {
      _buyStartedAt = null;
      onFailed?.call('$e');
    }
  }

  /// When [buy] last opened Play's purchase sheet, until Play reports how it
  /// went (any status but pending, in [handle]).
  DateTime? _buyStartedAt;

  /// How long a purchase sheet counts as open with nothing heard from Play.
  /// Past it the sheet is taken to be gone, so a purchase Play never reports
  /// cannot hold the app's table connection open for ever.
  static const buyingFor = Duration(minutes: 10);

  /// True while Play's purchase sheet is (as far as this app knows) in front
  /// of the player: from [buy] until Play reports the result, at most
  /// [buyingFor]. The sheet puts the app in the background, and GameState
  /// does not close the table's connection meanwhile (owner, 27 Sep 2026;
  /// [GameState.handleLifecycle]).
  bool get buying {
    final at = _buyStartedAt;
    return at != null && DateTime.now().difference(at) < buyingFor;
  }

  /// Marks a purchase sheet as open, as [buy] does — for a test.
  @visibleForTesting
  void debugStartBuying() => _buyStartedAt = DateTime.now();

  /// Finishes a purchase the server has banked: consumes it, so the pack can
  /// be bought again and [redeliver] stops bringing it back. A consume that
  /// fails (no network) leaves it owned, and the next session's [redeliver]
  /// posts it again — the server answers "already banked" — and consumes it
  /// then.
  Future<void> _finish(PurchaseDetails p) async {
    bool consumed;
    try {
      consumed = await (_consumeOverride?.call(p) ?? _consume(p));
    } catch (_) {
      consumed = false;
    }
    if (consumed) {
      _finished.add(_tokenOf(p));
    } else if (p.pendingCompletePurchase) {
      // Acknowledge at least (the server does too when it credits), so Play
      // never refunds a purchase whose chips are already in the wallet.
      try {
        await _iap.completePurchase(p);
      } catch (_) {}
    }
  }

  Future<bool> _consume(PurchaseDetails p) async {
    if (store != Store.play) {
      // The App Store: finishing the transaction is the whole of it.
      await _iap.completePurchase(p);
      return true;
    }
    final android = _iap
        .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
    final r = await android.consumePurchase(p);
    return r.responseCode == BillingResponse.ok;
  }

  /// What one purchase is known by across deliveries: Play's purchase token,
  /// or the App Store's transaction id — the signed transaction itself is
  /// signed afresh each time StoreKit hands it over, so two deliveries of one
  /// purchase carry different strings.
  String _tokenOf(PurchaseDetails p) {
    if (store == Store.appStore && (p.purchaseID ?? '').isNotEmpty) {
      return p.purchaseID!;
    }
    final token = p.verificationData.serverVerificationData;
    return token.isNotEmpty ? token : (p.purchaseID ?? '');
  }

  /// Everything Play reports — the stream's updates and [redeliver]'s owned
  /// purchases alike.
  @visibleForTesting
  Future<void> handle(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      // Play has answered: the sheet is closed, whatever it decided.
      if (p.status != PurchaseStatus.pending) _buyStartedAt = null;
      switch (p.status) {
        case PurchaseStatus.pending:
          onPending?.call();

        case PurchaseStatus.error:
          onFailed?.call(p.error?.message ?? notLaunched);
          // Still complete it: an errored purchase that is never completed is
          // re-delivered on every launch forever.
          if (p.pendingCompletePurchase) await _iap.completePurchase(p);

        case PurchaseStatus.canceled:
          if (p.pendingCompletePurchase) await _iap.completePurchase(p);

        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // The order here is the whole point — see the class doc. Credit
          // first; consume only if that succeeded. A failure leaves the
          // purchase owned with Play, and the next session's [redeliver]
          // tries again.
          final token = _tokenOf(p);
          if (_finished.contains(token) || !_delivering.add(token)) continue;
          try {
            final delivered = await onDeliver?.call(p) ?? false;
            if (delivered) await _finish(p);
          } finally {
            _delivering.remove(token);
          }
      }
    }
  }
}

/// Whether the server's refusal of a Play receipt is FINAL — the purchase is
/// then finished with Play (consumed) rather than delivered again.
///
/// Only a verdict on the receipt itself is final: 400 (an unknown product, a
/// malformed request) and 402 (`purchase_unverified`: Google does not confirm
/// a completed purchase). Everything else is the server's side of the story
/// or the session's — 401/403 (a lapsed or replaced sign-in), 408/429, any
/// 5xx (Google unreachable, a credentials problem, the store switched off) —
/// and the player may well have paid, so the purchase stays owned and the
/// next session posts it again. Consuming on one of those, now that consuming
/// is what finishes a purchase, would throw a paid receipt away for good.
///
/// Nor is a 404 final: no server this app talks to answers a purchase route
/// with one except a server that does not have the route yet — an iOS build
/// reaching a server from before `/api/purchases/apple` — and that says
/// nothing about the receipt.
bool receiptRefusalIsFinal(int? status) =>
    status != null &&
    status >= 400 &&
    status < 500 &&
    status != 401 &&
    status != 403 &&
    status != 404 &&
    status != 408 &&
    status != 429;
