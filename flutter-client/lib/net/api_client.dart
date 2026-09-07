import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/dtos.dart';

/// Thrown when the server refuses a request. The message is the server's own,
/// so it is safe to put in front of the player.
class ApiException implements Exception {
  ApiException(this.message);
  final String message;
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
    final map = json is Map ? Map<String, dynamic>.from(json) : <String, dynamic>{};

    if (r.statusCode >= 400) {
      final error = map['error'];
      final message = error is Map ? error['message'] : map['message'];
      throw ApiException('$message'.isEmpty || message == null
          ? 'Request failed (${r.statusCode})'
          : '$message');
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

  /// Re-reads the account, so chips, stats and reward timers stay current.
  Future<User> me(String token) async {
    final r = await http.get(_uri('/api/auth/me'), headers: _headers(token));
    final j = _decode(r);
    return User.fromJson(Map<String, dynamic>.from(j['user'] as Map));
  }

  /// The bundled pictures a player can choose between (requirement 21).
  Future<List<ProfilePicture>> profilePictures() async {
    final r = await http.get(_uri('/api/profiles'), headers: _headers());
    final j = _decode(r);
    return (j['profiles'] as List? ?? [])
        .map((e) => ProfilePicture.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Picks a bundled picture, or null to fall back to the provider's. The
  /// server refuses the change once the player is seated at a table.
  Future<User> setAvatar(String token, String? avatarId) async {
    final r = await http.post(
      _uri('/api/profile/avatar'),
      headers: _headers(token),
      body: jsonEncode({'avatar': avatarId}),
    );
    final j = _decode(r);
    return User.fromJson(Map<String, dynamic>.from(j['user'] as Map));
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

  /// Claims a reward. [kind] is "milestone" (requirement 17) or "bonus"
  /// (requirement 18). The server decides whether it is actually due.
  Future<({User? user, int awarded, String message})> claimReward(
    String token,
    String kind,
  ) async {
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
      awarded: (j['awarded'] as num?)?.toInt() ?? 0,
      message: '${j['message'] ?? ''}',
    );
  }
}
