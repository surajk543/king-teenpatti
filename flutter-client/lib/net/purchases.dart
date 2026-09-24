import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart'
    show BillingResponse;
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

/// The Google Play side of the chip store.
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
class Purchases {
  Purchases({
    InAppPurchase? iap,
    @visibleForTesting Future<bool> Function(PurchaseDetails purchase)? consume,
    @visibleForTesting Future<List<PurchaseDetails>> Function()? owned,
    @visibleForTesting this._available = false,
  }) : _iapOverride = iap,
       _consumeOverride = consume,
       _ownedOverride = owned;

  final InAppPurchase? _iapOverride;

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
  /// Services, on a build side-loaded outside Play, anywhere Play is
  /// unavailable — and on iOS, see [start] — none of which are errors, so the
  /// store should say so plainly rather than fail when the button is pressed.
  bool get available => _available;

  /// Subscribes to Play. Safe to call once at startup; further calls are
  /// ignored.
  ///
  /// **Android only, deliberately.** StoreKit works and `in_app_purchase`
  /// supports iOS, but the half that matters does not: a receipt goes to
  /// `POST /api/purchases/google`, which verifies it with Google and banks the
  /// chips. Apple's receipt is not a Play token, so the server would refuse it
  /// — and `GameState._deliverPurchase` completes a refused purchase to stop an
  /// endless redelivery loop. The player would have paid Apple and been given
  /// nothing. Leaving [available] false is what keeps that impossible: the
  /// shelf still shows its prices and Buy answers `storeNotLive`.
  ///
  /// Turning it on means an `/api/purchases/apple` route on the server that
  /// verifies with the App Store Server API, and Apple products created with
  /// these same ids. Until both exist this stays as it is.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    if (!Platform.isAndroid) return;
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
  Future<List<PurchaseDetails>> _queryOwned() async {
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
      onFailed?.call('Google Play is not available on this device.');
      return;
    }
    final param = PurchaseParam(productDetails: product);
    try {
      await _iap.buyConsumable(purchaseParam: param, autoConsume: false);
    } catch (e) {
      onFailed?.call('$e');
    }
  }

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
    if (!Platform.isAndroid) {
      await _iap.completePurchase(p);
      return true;
    }
    final android = _iap
        .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
    final r = await android.consumePurchase(p);
    return r.responseCode == BillingResponse.ok;
  }

  static String _tokenOf(PurchaseDetails p) {
    final token = p.verificationData.serverVerificationData;
    return token.isNotEmpty ? token : (p.purchaseID ?? '');
  }

  /// Everything Play reports — the stream's updates and [redeliver]'s owned
  /// purchases alike.
  @visibleForTesting
  Future<void> handle(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      switch (p.status) {
        case PurchaseStatus.pending:
          onPending?.call();

        case PurchaseStatus.error:
          onFailed?.call(
            p.error?.message ?? 'The purchase did not go through.',
          );
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
bool receiptRefusalIsFinal(int? status) =>
    status != null &&
    status >= 400 &&
    status < 500 &&
    status != 401 &&
    status != 403 &&
    status != 408 &&
    status != 429;
