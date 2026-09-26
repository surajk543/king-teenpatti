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

/// A Lucky Draw spin refused because the wheel has not recharged yet: 409
/// `lucky_draw_not_ready`, carrying [readyAt], the epoch ms the server will
/// allow the next spin — so the screen can count down to the server's moment
/// rather than its own.
class LuckyDrawNotReady extends ApiException {
  LuckyDrawNotReady(super.message, {required this.readyAt})
    : super(code: 'lucky_draw_not_ready', status: 409);
  final int readyAt;
}

/// What `GET /api/tables` answered ([ApiClient.tableConfig]).
sealed class TableConfigAnswer {
  const TableConfigAnswer();
}

/// A catalogue, already checked: [body] is the server's JSON exactly as it
/// came (what the phone keeps), [config] the menu read from it.
final class TableConfigFresh extends TableConfigAnswer {
  const TableConfigFresh({required this.body, required this.config});
  final Map<String, dynamic> body;
  final GameConfig config;
}

/// 304: the catalogue named by the `If-None-Match` version is still the one
/// the server enforces, so the copy already held is current.
final class TableConfigNotModified extends TableConfigAnswer {
  const TableConfigNotModified();
}

/// 404: a server that predates the catalogue. `session:ready`'s menu is the
/// whole story there, and asking again will not change the answer.
final class TableConfigAbsent extends TableConfigAnswer {
  const TableConfigAbsent();
}

/// The REST half of the server: everything that is not live gameplay.
///
/// Gameplay itself runs over the socket — see [GameConnection]. These calls are
/// the ones that make sense as one-shot requests: signing in, re-reading the
/// account, and claiming rewards.
class ApiClient {
  ApiClient(this.baseUrl, {this.client});

  final String baseUrl;

  /// For tests. The app leaves it null and every call opens its own
  /// connection, as they always have.
  final http.Client? client;

  /// How long the table catalogue may take before the menu already on screen
  /// is simply kept. It is never waited on by anything the player sees.
  static const tableConfigTimeout = Duration(seconds: 12);

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

  /// The table catalogue: every table the server opens and every figure it
  /// plays by (`GET /api/tables`, public, no token).
  ///
  /// [version] is the catalogue already held, sent as `If-None-Match`; the
  /// server answers 304 while it is still current, so a login that changed
  /// nothing costs a round trip and no body. The 304 is read BEFORE the body
  /// is decoded — it has none — and a 404 is an older server with no
  /// catalogue, answered as such rather than thrown, so nothing retries it.
  ///
  /// A 200 whose body is not a usable catalogue ([GameConfig.fromCatalogue])
  /// throws, as does any other refusal, a timeout ([tableConfigTimeout]) or a
  /// network failure: the caller keeps the menu it has.
  Future<TableConfigAnswer> tableConfig({String? version}) async {
    final uri = _uri('/api/tables');
    final headers = {
      'Accept': 'application/json',
      if (version != null && version.isNotEmpty) 'If-None-Match': '"$version"',
    };
    final client = this.client;
    final r =
        await (client != null
                ? client.get(uri, headers: headers)
                : http.get(uri, headers: headers))
            .timeout(tableConfigTimeout);
    if (r.statusCode == 304) return const TableConfigNotModified();
    if (r.statusCode == 404) return const TableConfigAbsent();
    final body = _decode(r);
    final config = GameConfig.fromCatalogue(body);
    if (config == null) {
      throw ApiException(
        'The table menu could not be read',
        code: 'invalid_table_config',
        status: r.statusCode,
      );
    }
    return TableConfigFresh(body: body, config: config);
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

  /// The emoji catalogue (owner, 26 Sep 2026): `GET /api/emojis`, active
  /// rows in the catalogue's order. The token is optional to the server and
  /// wanted here, as for [profilePictures]: without it every premium emoji
  /// comes back locked. A server that predates emojis answers 404, which is
  /// an empty catalogue rather than a failure.
  Future<List<EmojiItem>> emojis({String? token}) async {
    final r = await http.get(_uri('/api/emojis'), headers: _headers(token));
    if (r.statusCode == 404) return const [];
    final j = _decode(r);
    return (j['emojis'] as List? ?? [])
        .whereType<Map>()
        .map((e) => EmojiItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Buys a premium emoji from the wallet its currency names: `POST
  /// /api/emojis/buy {emojiId}`. `charged` is false when it was already owned
  /// and running; `emoji` is the row as it now stands for this player.
  ///
  /// Refusals arrive as [ApiException] with the server's code:
  /// `unknown_emoji`, `emoji_retired`, `emoji_free` (400),
  /// `emoji_unaffordable` and `seated` (409 — a chip-priced emoji is sold in
  /// the lobby only).
  Future<({User user, EmojiItem? emoji, bool charged, int spent})> buyEmoji(
    String token,
    int emojiId,
  ) async {
    final r = await http.post(
      _uri('/api/emojis/buy'),
      headers: _headers(token),
      body: jsonEncode({'emojiId': emojiId}),
    );
    final j = _decode(r);
    return (
      user: User.fromJson(Map<String, dynamic>.from(j['user'] as Map)),
      emoji: j['emoji'] is Map
          ? EmojiItem.fromJson(Map<String, dynamic>.from(j['emoji'] as Map))
          : null,
      charged: j['charged'] == true,
      spent: (j['spent'] as num?)?.toInt() ?? 0,
    );
  }

  /// The table-picture catalogue (owner, 15 Sep 2026): the cloths a player
  /// can lay on their own table, each with a day and a night file. The token
  /// is optional to the server and wanted here, as for [profilePictures]: it
  /// is what marks the ones this player has bought as `owned`.
  Future<List<TablePicture>> tablePictures([String? token]) async {
    final r = await http.get(
      _uri('/api/table-pictures'),
      headers: _headers(token),
    );
    final j = _decode(r);
    return (j['tablePictures'] as List? ?? [])
        .map((e) => TablePicture.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Lays a table picture, or null for the table as it comes. Allowed at a
  /// table — the picture is drawn by this player alone — and refused for a
  /// premium picture they have not bought (`picture_locked`).
  Future<User> useTablePicture(String token, int? pictureId) async {
    final r = await http.post(
      _uri('/api/table-pictures/use'),
      headers: _headers(token),
      body: jsonEncode({'pictureId': pictureId}),
    );
    final j = _decode(r);
    return User.fromJson(Map<String, dynamic>.from(j['user'] as Map));
  }

  /// Buys a premium table picture from the wallet its currency names. As with
  /// [buyPicture], buying does not lay it — that is [useTablePicture] — and
  /// `charged` is false when it was already owned.
  Future<({User user, bool charged, int spent})> buyTablePicture(
    String token,
    int pictureId,
  ) async {
    final r = await http.post(
      _uri('/api/table-pictures/buy'),
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

  /// The Lucky Draw (owner, 24 Sep 2026): `GET /api/lucky-draw` — the draw
  /// the lobby opens, its six slots in wheel order and when this player may
  /// next spin. No weights: the server draws.
  ///
  /// Null when there is no wheel to show — 503 `lucky_draw_unavailable` (no
  /// draw open, or none with a prize left to win) or 404 (a server that
  /// predates the draw). Neither is a fault to report: the lobby simply shows
  /// no Lucky Draw.
  Future<LuckyDrawState?> luckyDraw(String token) async {
    final r = await http.get(_uri('/api/lucky-draw'), headers: _headers(token));
    if (r.statusCode == 404 || r.statusCode == 503) return null;
    return LuckyDrawState.fromJson(_decode(r));
  }

  /// One spin of the Lucky Draw: `POST /api/lucky-draw/spin {actionId, code}`.
  ///
  /// The server draws the slot, grants its prize and records the spin in one
  /// transaction; nothing sent here names a prize. [code] is the draw on
  /// screen, so the wheel spun is the one the player is looking at.
  /// [actionId] is minted once per spin and sent again on a retry of it: the
  /// server answers a replay with the same spin, `replayed: true`, and grants
  /// nothing twice.
  ///
  /// A spin before the wheel has recharged throws [LuckyDrawNotReady]; every
  /// other refusal is an [ApiException] with the server's code — `seated`
  /// (409: the draw is spun from the lobby), `lucky_draw_unavailable` (503),
  /// `invalid_action_id` (400).
  Future<LuckySpin> spinLuckyDraw(
    String token,
    String actionId, {
    String? code,
  }) async {
    final r = await http.post(
      _uri('/api/lucky-draw/spin'),
      headers: _headers(token),
      body: jsonEncode({
        'actionId': actionId,
        if (code != null && code.isNotEmpty) 'code': code,
      }),
    );
    if (r.statusCode == 409) {
      Object? body;
      try {
        body = jsonDecode(r.body);
      } on FormatException {
        body = null;
      }
      if (body is Map && body['error'] == 'lucky_draw_not_ready') {
        final readyAt = body['readyAt'];
        throw LuckyDrawNotReady(
          '${body['message'] ?? ''}',
          readyAt: readyAt is num ? readyAt.toInt() : 0,
        );
      }
    }
    return LuckySpin.fromJson(_decode(r));
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
