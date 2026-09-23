import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/dtos.dart';

/// The table catalogue as the phone last received it (`GET /api/tables`).
class CachedTableConfig {
  const CachedTableConfig({
    required this.version,
    required this.fetchedAt,
    required this.body,
    required this.config,
  });

  /// The catalogue's `version` — what the next fetch sends as `If-None-Match`.
  final String version;

  /// When it was fetched, epoch milliseconds.
  final int fetchedAt;

  /// The server's JSON exactly as it came, so a later build can read keys
  /// this one does not know about.
  final Map<String, dynamic> body;

  /// The menu read from [body].
  final GameConfig config;
}

/// The phone's copy of the table catalogue, so a cold start opens the lobby
/// on the menu this server last described rather than on the three tables
/// [GameConfig.fallback] names — the server's own answer arrives a moment
/// later and wins.
///
/// One SharedPreferences entry under [key]: `{"schema":1, "version",
/// "fetchedAt", "body"}`. An entry that is not that — corrupt, or written by
/// a build with another [schema] — is discarded, never half-read. A body that
/// is not a usable catalogue ([GameConfig.fromCatalogue]) is never written,
/// so a broken answer cannot replace a good copy. It is the SERVER's menu, not
/// the player's, so it is kept across sign-out and account deletion.
///
/// Kept apart from [GameState] for the same reason the consent flag and the
/// theme are: it can be tested without a session.
class TableConfigCache {
  const TableConfigCache._();

  static const key = 'tableConfig';

  /// The entry's own format. Bump it when the envelope changes; an entry of
  /// any other schema is discarded on read.
  static const schema = 1;

  /// The cached catalogue, or null when there is none worth using.
  static CachedTableConfig? read(SharedPreferences prefs) {
    final raw = prefs.getString(key);
    if (raw == null) return null;
    final entry = decode(raw);
    // Discarded, not merely ignored: the next good fetch would overwrite it
    // anyway, and a copy that can never be read is only noise until then.
    if (entry == null) unawaited(prefs.remove(key));
    return entry;
  }

  /// Keeps [body] as the phone's copy. Answers whether it was written: false
  /// when [body] is not a usable catalogue, which leaves the copy already
  /// kept exactly as it was.
  static Future<bool> write(
    Map<String, dynamic> body, {
    SharedPreferences? prefs,
    DateTime? now,
  }) async {
    final config = GameConfig.fromCatalogue(body);
    final version = config?.tableConfigVersion;
    if (config == null || version == null) return false;
    prefs ??= await SharedPreferences.getInstance();
    return prefs.setString(
      key,
      jsonEncode({
        'schema': schema,
        'version': version,
        'fetchedAt': (now ?? DateTime.now()).millisecondsSinceEpoch,
        'body': body,
      }),
    );
  }

  static Future<void> clear([SharedPreferences? prefs]) async {
    prefs ??= await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  /// Reads one stored entry, or null when it is not a schema-[schema] entry
  /// holding a usable catalogue whose version matches its envelope.
  static CachedTableConfig? decode(String raw) {
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (json is! Map) return null;
    if (json['schema'] != schema) return null;
    final version = json['version'];
    final body = json['body'];
    if (version is! String || body is! Map) return null;
    final map = Map<String, dynamic>.from(body);
    final config = GameConfig.fromCatalogue(map);
    if (config == null || config.tableConfigVersion != version) return null;
    final fetchedAt = json['fetchedAt'];
    return CachedTableConfig(
      version: version,
      fetchedAt: fetchedAt is num ? fetchedAt.toInt() : 0,
      body: map,
      config: config,
    );
  }
}

/// Which menu the lobby shows, when the table catalogue and `session:ready`
/// can both describe it (23 Sep 2026).
///
/// Pure, so every case is a unit test rather than a session. The rules:
///  * `session:ready` with NO `tableConfigVersion` is a server that predates
///    the catalogue: its config is the menu, exactly as before, and nothing
///    is fetched (there is nothing to fetch).
///  * A version equal to the catalogue held: the catalogue stays — it carries
///    every figure — and only [GameConfig.minClientBuild], which is
///    session-scoped, is taken from the session.
///  * A different version: the session's config is the menu until the
///    catalogue that matches it has been fetched.
///  * A catalogue that arrives (a fetch, or a 304 confirming the one held) is
///    shown only when no session has named a version yet or it is the version
///    the latest session named; otherwise it is late, from before the server
///    changed its menu, and is kept but not shown.
class MenuPrecedence {
  const MenuPrecedence._();

  /// `session:ready` brought [session]; [catalogue] is the richest menu held
  /// (fetched or cached), or null. Answers the menu to show and whether the
  /// catalogue should be fetched again.
  static ({GameConfig config, bool refetch}) onSession({
    required GameConfig session,
    required GameConfig? catalogue,
  }) {
    final announced = session.tableConfigVersion;
    if (announced == null) return (config: session, refetch: false);
    if (catalogue != null && catalogue.tableConfigVersion == announced) {
      return (
        config: catalogue.copyWith(minClientBuild: session.minClientBuild),
        refetch: false,
      );
    }
    return (config: session, refetch: true);
  }

  /// A catalogue arrived. [announced] is the version the latest
  /// `session:ready` named (null while none has, or from an older server) and
  /// [minClientBuild] that session's floor. Answers the menu to show, or null
  /// to leave the one on screen.
  static GameConfig? onCatalogue({
    required GameConfig catalogue,
    required String? announced,
    required int minClientBuild,
  }) {
    if (announced != null && announced != catalogue.tableConfigVersion) {
      return null;
    }
    return catalogue.copyWith(minClientBuild: minClientBuild);
  }
}
