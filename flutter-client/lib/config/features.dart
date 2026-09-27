/// What the app shows a player, where that is decided at BUILD time rather
/// than by the server.
///
/// Like `ServerConfig`, set with a define and never edited in code:
///
///     flutter build appbundle --release --dart-define-from-file=config/production.json   # Teen Patti only (the default)
///     flutter build apk --debug --dart-define=SHOW_POKER=true                            # the Poker family back in the lobby
abstract final class AppFeatures {
  /// Whether the app shows the Poker family: the lobby's Teen Patti and Poker
  /// engine cards and the four poker games behind them, the Poker view of a
  /// player's record, and the poker section of the rules reference.
  ///
  /// Off by default (owner, 27 Sep 2026: "do this change in UI only, remove
  /// poker category and In UI only show three cards seen, blind, variation").
  /// The switch is the APP's alone: the server still offers its poker tables
  /// (`session:ready.config.tables`, `GET /api/tables`), the phone still keeps
  /// the catalogue exactly as it came, and the poker felt, DTOs and texts are
  /// all still built in — the lobby simply does not show a way to them. With
  /// `SHOW_POKER=true` the lobby is the three-level one of 23 Sep 2026 again.
  ///
  /// A mutable static rather than a `const` ONLY so the tests can switch it
  /// (the poker lobby, its rules and its record stay covered with it on); the
  /// app never writes it.
  static bool poker = const bool.fromEnvironment('SHOW_POKER');
}
