// A Play purchase is consumed only after the server has banked it, and an
// owned (paid, not yet banked) purchase is handed to the server again at the
// start of every session (24 Sep 2026, owner's "fix all bugs"; release review
// RC-03). The plugin's default `autoConsume: true` consumed a pack the moment
// Play reported it — before the app had even heard of it — so a credit that
// failed on the network could never be retried: the player paid and got
// nothing.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:teenpatti/net/purchases.dart';

class _FakeIap implements InAppPurchase {
  bool? autoConsume;
  final completed = <String>[];

  @override
  Future<bool> buyConsumable({
    required PurchaseParam purchaseParam,
    bool autoConsume = true,
  }) async {
    this.autoConsume = autoConsume;
    return true;
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    completed.add(purchase.verificationData.serverVerificationData);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PurchaseDetails _purchase(
  String token, {
  PurchaseStatus status = PurchaseStatus.purchased,
  bool acknowledged = false,
}) => PurchaseDetails(
  purchaseID: 'GPA.$token',
  productID: 'chips_small',
  verificationData: PurchaseVerificationData(
    localVerificationData: '{}',
    serverVerificationData: token,
    source: 'google_play',
  ),
  transactionDate: '0',
  status: status,
)..pendingCompletePurchase = !acknowledged;

void main() {
  test('a purchase is bought with autoConsume off, so Play cannot consume it '
      'before the server has banked it', () async {
    final iap = _FakeIap();
    final purchases = Purchases(iap: iap, available: true);
    await purchases.buy(
      ProductDetails(
        id: 'chips_small',
        title: 'Chips',
        description: '',
        price: '₹49',
        rawPrice: 49,
        currencyCode: 'INR',
      ),
    );
    expect(iap.autoConsume, isFalse);
  });

  test('a purchase is consumed only once the server has banked it', () async {
    final consumed = <String>[];
    final iap = _FakeIap();
    final purchases = Purchases(
      iap: iap,
      available: true,
      consume: (p) async {
        consumed.add(p.verificationData.serverVerificationData);
        return true;
      },
    );

    var bank = false;
    purchases.onDeliver = (_) async => bank;

    // The credit failed (the network, a restart): nothing is finished, so
    // the purchase stays owned with Play for the next session.
    await purchases.handle([_purchase('t1')]);
    expect(consumed, isEmpty);
    expect(iap.completed, isEmpty);

    // Banked: consumed, so the pack can be bought again.
    bank = true;
    await purchases.handle([_purchase('t1')]);
    expect(consumed, ['t1']);
  });

  test('every session hands owned purchases to the server again, and leaves '
      'one still pending with the bank alone', () async {
    final consumed = <String>[];
    final delivered = <String>[];
    final purchases =
        Purchases(
            iap: _FakeIap(),
            available: true,
            consume: (p) async {
              consumed.add(p.verificationData.serverVerificationData);
              return true;
            },
            owned: () async => [
              _purchase('paid'),
              _purchase('waiting', status: PurchaseStatus.pending),
            ],
          )
          ..onDeliver = (p) async {
            delivered.add(p.verificationData.serverVerificationData);
            return true;
          };

    await purchases.start();
    await purchases.redeliver();
    expect(delivered, ['paid']);
    expect(consumed, ['paid']);

    // Finished in this run: a query answered before the consume landed does
    // not post it again.
    await purchases.redeliver();
    expect(delivered, ['paid']);
  });

  test(
    'a purchase the stream and a redelivery bring at once is posted once',
    () async {
      final gate = Completer<bool>();
      var posts = 0;
      final purchases =
          Purchases(
              iap: _FakeIap(),
              available: true,
              consume: (_) async => true,
              owned: () async => [_purchase('same')],
            )
            ..onDeliver = (_) {
              posts++;
              return gate.future;
            };

      final fromStream = purchases.handle([_purchase('same')]);
      final fromQuery = purchases.redeliver();
      await Future<void>.delayed(Duration.zero);
      gate.complete(true);
      await Future.wait([fromStream, fromQuery]);
      expect(posts, 1);
    },
  );

  test('a consume that fails still acknowledges, and the next session posts '
      'the purchase again', () async {
    final iap = _FakeIap();
    var consumeWorks = false;
    var posts = 0;
    final purchases =
        Purchases(
            iap: iap,
            available: true,
            consume: (_) async => consumeWorks,
            owned: () async => [_purchase('flaky')],
          )
          ..onDeliver = (_) async {
            posts++;
            return true;
          };

    await purchases.redeliver();
    expect(iap.completed, ['flaky']);
    expect(posts, 1);

    consumeWorks = true;
    await purchases.redeliver();
    expect(posts, 2);
  });

  test('only a verdict on the receipt itself finishes a refused purchase', () {
    // 400: unknown product / malformed; 402: Google does not confirm it.
    expect(receiptRefusalIsFinal(400), isTrue);
    expect(receiptRefusalIsFinal(402), isTrue);
    // A lapsed session, a throttle, the server or Google down: the player may
    // well have paid, so the purchase stays owned for the next session.
    for (final status in [null, 401, 403, 408, 429, 500, 502, 503]) {
      expect(receiptRefusalIsFinal(status), isFalse, reason: '$status');
    }
  });
}
