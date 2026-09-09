import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';

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
/// # Why completePurchase comes last
///
/// A purchase is only marked complete after OUR server has banked the chips.
/// Until then Play keeps re-delivering it, which is exactly what we want: if
/// the app dies between paying and crediting, the next launch gets the
/// purchase again and the credit happens then. Completing first would throw
/// the receipt away and the player would have paid for nothing.
///
/// The server is idempotent on the purchase token, so the repeat deliveries
/// this design invites cannot double-credit.
class Purchases {
  Purchases({InAppPurchase? iap}) : _iap = iap ?? InAppPurchase.instance;

  final InAppPurchase _iap;
  StreamSubscription<List<PurchaseDetails>>? _sub;

  /// Called for every purchase that reaches the "deliver it" stage. Must
  /// return true once the chips are safely credited; only then is the
  /// purchase completed with Play.
  Future<bool> Function(PurchaseDetails purchase)? onDeliver;

  /// Called when a purchase fails or is cancelled, with a message fit to show.
  void Function(String message)? onFailed;

  /// Called when a purchase is waiting on the player or their bank, so the UI
  /// can say "waiting for confirmation" rather than looking broken.
  void Function()? onPending;

  bool _available = false;

  /// Whether this device can buy at all. False on an emulator without Play
  /// Services, on a build side-loaded outside Play, and anywhere Play is
  /// unavailable — none of which are errors, so the store should say so
  /// plainly rather than fail when the button is pressed.
  bool get available => _available;

  /// Subscribes to Play. Safe to call once at startup; further calls are
  /// ignored.
  Future<void> start() async {
    if (_sub != null) return;
    try {
      _available = await _iap.isAvailable();
    } catch (_) {
      _available = false;
    }
    if (!_available) return;
    _sub = _iap.purchaseStream.listen(
      _onPurchases,
      onError: (Object e) => onFailed?.call('$e'),
    );
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
  /// consumed after delivery rather than held as an entitlement.
  Future<void> buy(ProductDetails product) async {
    if (!_available) {
      onFailed?.call('Google Play is not available on this device.');
      return;
    }
    final param = PurchaseParam(productDetails: product);
    try {
      await _iap.buyConsumable(purchaseParam: param);
    } catch (e) {
      onFailed?.call('$e');
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      switch (p.status) {
        case PurchaseStatus.pending:
          onPending?.call();

        case PurchaseStatus.error:
          onFailed?.call(p.error?.message ?? 'The purchase did not go through.');
          // Still complete it: an errored purchase that is never completed is
          // re-delivered on every launch forever.
          if (p.pendingCompletePurchase) await _iap.completePurchase(p);

        case PurchaseStatus.canceled:
          if (p.pendingCompletePurchase) await _iap.completePurchase(p);

        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // The order here is the whole point — see the class doc. Credit
          // first; complete only if that succeeded. A failure leaves the
          // purchase pending with Play, and the next launch tries again.
          final delivered = await onDeliver?.call(p) ?? false;
          if (delivered && p.pendingCompletePurchase) {
            await _iap.completePurchase(p);
          }
      }
    }
  }
}
