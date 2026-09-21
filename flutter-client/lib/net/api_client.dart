import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/dtos.dart';

/// Thrown when the server refuses a request. The message is the server's own,
/// so it is safe to put in front of the player.
class ApiException implements Exception {
  ApiException(this.message, {this.code, this.status});
  final String message;

  /// The server's snake_case code (`{error: code, message}`), when it sent
  /// one: what a caller branches on, since the message is English.
  final String? code;

  /// The HTTP status, when the refusal came from a response.
  final int? status;
  @override
  String toString() => message;
}

/// The REST half of the server: everything that is not live gameplay.
///
/// Gameplay itself runs over the socket — see [GameConnection]. These calls are
/// the ones that make sense as one-shot requests: signing in, re-reading the
/// account, and claiming rewards.
class ApiClient {
  ApiClient(this.baseUrl);

  final String baseUrl;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> _headers([String? token]) => {
    'Content-Type': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Map<String, dynamic> _decode(http.Response r) {
    final body = r.body.isEmpty ? '{}' : r.body;
    final json = jsonDecode(body);
    final map = json is Map
        ? Map<String, dynamic>.from(json)
        : <String, dynamic>{};

    if (r.statusCode >= 400) {
      final error = map['error'];
      final message = error is Map ? error['message'] : map['message'];
      final code = error is String
          ? error
          : error is Map && error['code'] is String
          ? error['code'] as String
          : null;
      throw ApiException(
        '$message'.isEmpty || message == null
            ? 'Request failed (${r.statusCode})'
            : '$message',
        code: code,
        status: r.statusCode,
      );
    }
    return map;
  }

  /// Signs in. Guest play is keyed to [deviceId], so the same device keeps its
  /// chips across launches (requirements 1 and 7).
  Future<({String token, User user, bool isNew, int welcomeChips})> loginGuest({
    required String deviceId,
    String? displayName,
  }) async {
    final r = await http.post(
      _uri('/api/auth/login'),
      headers: _headers(),
      body: jsonEncode({
        'provider': 'guest',
        'deviceId': deviceId,
        if (displayName != null && displayName.trim().isNotEmpty)
          'displayName': displayName.trim(),
      }),
    );

    final j = _decode(r);
    return (
      token: '${j['token']}',
      user: User.fromJson(Map<String, dynamic>.from(j['user'] as Map)),
      isNew: j['isNew'] == true,
      welcomeChips: (j['welcomeChips'] as num?)?.toInt() ?? 0,
    );
  }

  /// Signs in with a token from Google or Facebook.
  ///
  /// The SAME endpoint and the same response as guest play — the server takes
  /// `provider` plus one credential and answers with a session either way, so
  /// nothing downstream of this needs to know which door the player came in
  /// by. Google sends the OpenID `idToken`, Facebook the `accessToken`; the
  /// server verifies it with the provider before minting anything.
  ///
  /// The server answers 503 `provider_unconfigured` when it has no credentials
  /// for that provider, which is a deployment state rather than a user error —
  /// the caller shows it as one.
  Future<({String token, User user, bool isNew, int welcomeChips})>
  loginProvider({
    required String provider,
    required String credential,
    String? displayName,
  }) async {
    final r = await http.post(
      _uri('/api/auth/login'),
      headers: _headers(),
      body: jsonEncode({
        'provider': provider,
        // The key differs per provider; the server reads whichever it needs.
        if (provider == 'google') 'idToken': credential,
        if (provider == 'facebook') 'accessToken': credential,
        if (displayName != null && displayName.trim().isNotEmpty)
          'displayName': displayName.trim(),
      }),
    );

    final j = _decode(r);
    return (
      token: '${j['token']}',
      user: User.fromJson(Map<String, dynamic>.from(j['user'] as Map)),
      isNew: j['isNew'] == true,
      welcomeChips: (j['welcomeChips'] as num?)?.toInt() ?? 0,
    );
  }

  /// Re-reads the account, so chips, stats and reward timers stay current.
  Future<User> me(String token) async {
    final r = await http.get(_uri('/api/auth/me'), headers: _headers(token));
    final j = _decode(r);
    return User.fromJson(Map<String, dynamic>.from(j['user'] as Map));
  }

  /// The picture catalogue (requirement 21).
  ///
  /// The token is optional to the server but wanted here: it is what makes
  /// `owned` true for the premium pictures this player has already bought,
  /// and without it every one of them comes back locked.
  Future<List<ProfilePicture>> profilePictures([String? token]) async {
    final r = await http.get(_uri('/api/profiles'), headers: _headers(token));
    final j = _decode(r);
    return (j['profiles'] as List? ?? [])
        .map(
          (e) => ProfilePicture.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList();
  }

  /// Wears a catalogue picture, or null to fall back to the provider's. The
  /// server refuses the change once the player is seated at a table, and
  /// refuses a premium picture they have not bought.
  Future<User> setAvatar(String token, int? pictureId) async {
    final r = await http.post(
      _uri('/api/profile/avatar'),
      headers: _headers(token),
      body: jsonEncode({'avatar': pictureId}),
    );
    final j = _decode(r);
    return User.fromJson(Map<String, dynamic>.from(j['user'] as Map));
  }

  /// Buys a premium picture with chips. Returns the fresh wallet; whether the
  /// call actually charged is in `charged` (false when it was already owned).
  ///
  /// Buying does not wear the picture — that is [setAvatar] — so the two
  /// refusals stay separate and the chips are spent by one request only.
  Future<({User user, bool charged, int spent})> buyPicture(
    String token,
    int pictureId,
  ) async {
    final r = await http.post(
      _uri('/api/profile/picture/buy'),
      headers: _headers(token),
      body: jsonEncode({'pictureId': pictureId}),
    );
    final j = _decode(r);
    return (
      user: User.fromJson(Map<String, dynamic>.from(j['user'] as Map)),
      charged: j['charged'] == true,
      spent: (j['spent'] as num?)?.toInt() ?? 0,
    );
  }

  /// Trades diamonds for missiles (owner, 14 Sep 2026): `POST
  /// /api/store/missiles {packId, requestId}`, in the lobby or at a table.
  ///
  /// No counts are sent — the server holds the packs (1 missile for 5
  /// diamonds, up to 30 for 100) and answers with what it spent and gave.
  /// [requestId] is minted once per attempt and sent again on a retry of that
  /// attempt: a replay answers `charged: false` and charges nothing twice.
  ///
  /// Refusals arrive as [ApiException] with a [ApiException.code]:
  /// `not_enough_diamonds` (409), `unknown_pack` or `invalid_request_id`
  /// (400).
  Future<({User user, bool charged, int diamonds, int missiles})> tradeMissiles(
    String token,
    String packId,
    String requestId,
  ) async {
    final r = await http.post(
      _uri('/api/store/missiles'),
      headers: _headers(token),
      body: jsonEncode({'packId': packId, 'requestId': requestId}),
    );
    final j = _decode(r);
    return (
      user: User.fromJson(Map<String, dynamic>.from(j['user'] as Map)),
      charged: j['charged'] == true,
      diamonds: (j['diamonds'] as num?)?.toInt() ?? 0,
      missiles: (j['missiles'] as num?)?.toInt() ?? 0,
    );
  }

  /// Requirement 29: renames the player. The server validates the name and
  /// refuses the change while they are seated at a table.
  Future<User> setDisplayName(String token, String name) async {
    final r = await http.post(
      _uri('/api/profile/name'),
      headers: _headers(token),
      body: jsonEncode({'name': name}),
    );
    final j = _decode(r);
    return User.fromJson(Map<String, dynamic>.from(j['user'] as Map));
  }

  /// Deletes the player's account, permanently.
  ///
  /// Google Play requires an in-app route to this, and the game creates an
  /// account on first launch, so every player has one to delete.
  ///
  /// The server refuses while the player is seated (409 `seated`), because a
  /// seated wallet is only brought up to date at the three checkpoints and
  /// emptying it mid-hand would settle that hand against a balance that has
  /// stopped existing. The caller should send the player to the lobby first.
  ///
  /// After this returns the token still verifies but names nothing, so every
  /// later request is answered `unknown_user`. Clear the stored token and
  /// device id, or the next launch spends its first request finding that out.
  Future<void> deleteAccount(String token) async {
    final r = await http.delete(_uri('/api/account'), headers: _headers(token));
    _decode(r);
  }

  /// Hands a Google Play receipt to the server for verification.
  ///
  /// Sends only what Play gave us — which product, and the purchase token. No
  /// amount: the server holds the catalogue and decides what a product is
  /// worth, because a client that could name its own figure could mint chips.
  ///
  /// `credited` false with a 200 means this receipt had already been banked
  /// (a retry, or a purchase restored on a new install). That is success: the
  /// chips are in the wallet, and the caller should finish the Play
  /// transaction rather than leave it to be delivered again.
  Future<
    ({
      User? user,
      bool credited,
      int chips,
      int diamonds,
      int hammers,
      int missiles,
      int balance,
    })
  >
  redeemPurchase(String token, String productId, String purchaseToken) async {
    final r = await http.post(
      _uri('/api/purchases/google'),
      headers: _headers(token),
      body: jsonEncode({
        'productId': productId,
        'purchaseToken': purchaseToken,
      }),
    );
    final j = _decode(r);
    return (
      user: j['user'] is Map
          ? User.fromJson(Map<String, dynamic>.from(j['user'] as Map))
          : null,
      credited: j['credited'] == true,
      chips: (j['chips'] as num?)?.toInt() ?? 0,
      // The product decides the wallets. A chip, diamond or hammer pack fills
      // one of them and a Premium Package (owner, 14 Sep 2026) three at once:
      // chips, missiles and hammers, all non-zero together. An older server
      // sends no `diamonds`, `hammers` or `missiles`.
      diamonds: (j['diamonds'] as num?)?.toInt() ?? 0,
      hammers: (j['hammers'] as num?)?.toInt() ?? 0,
      missiles: (j['missiles'] as num?)?.toInt() ?? 0,
      balance: (j['balance'] as num?)?.toInt() ?? 0,
    );
  }

  /// Claims a reward. [kind] is "milestone" (requirement 17) or "bonus"
  /// (requirement 18). The server decides whether it is actually due, and
  /// answers 200 `{claimed:true, amount, milestone|readyAt, user}` or 409
  /// `{error, message, readyAt?, user}`.
  ///
  /// Read `claimed`, and read the amount from `amount` — NOT from `awarded`,
  /// which no endpoint has ever sent. Keying success off a missing field meant
  /// every successful collection fell through to the refusal branch and told
  /// the player "Not ready yet" while the chips landed in their wallet.
  Future<({User? user, bool claimed, int amount, int readyAt, String message})>
  claimReward(String token, String kind) async {
    final r = await http.post(
      _uri('/api/rewards/$kind'),
      headers: _headers(token),
      body: jsonEncode(const {}),
    );
    final j = _decode(r);
    return (
      user: j['user'] is Map
          ? User.fromJson(Map<String, dynamic>.from(j['user'] as Map))
          : null,
      claimed: j['claimed'] == true,
      amount: (j['amount'] as num?)?.toInt() ?? 0,
      readyAt: (j['readyAt'] as num?)?.toInt() ?? 0,
      message: '${j['message'] ?? ''}',
    );
  }
}
