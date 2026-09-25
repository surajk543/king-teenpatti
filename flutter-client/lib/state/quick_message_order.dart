/// The chat drawer's quick messages as this phone's player has arranged them:
/// the owner's set lines and the player's own, in the player's order (owner,
/// 25 Sep 2026: "make sure user can drag and reorder the quick message in UI …
/// save that order in UI only", and then "add a button in quick message
/// drawer so that when user clicks and type and save that typed message will
/// be seen in quick message list … when user restart the app, make sure
/// ordering and custom message should be preserved in phone").
///
/// Everything here is kept on this phone alone (SharedPreferences); nothing
/// about it reaches the server. A line goes out as the words it shows, through
/// the same chat message any typed line is.
///
/// An order is a list of KEYS: a set line's is its index into
/// [Strings.quickMessages] as a decimal string ([builtInQuickKey]) — its place
/// in the owner's list, not its text, so one arrangement holds in every
/// language and survives a translation being reworded — and a line of the
/// player's own is `c:` and its id ([customQuickKey]). An order saved before
/// the player could add lines is the same list of index strings, and reads as
/// it did.
///
/// Pure functions, so the rules are tested without a widget: GameState keeps
/// what was saved and asks [normaliseQuickOrder] for the order to draw.
library;

import 'dart:convert';

/// The SharedPreferences key the order lives under: [builtInQuickKey] and
/// [customQuickKey] strings, in the order the player put them.
const quickOrderPrefsKey = 'quickMessageOrder';

/// The SharedPreferences key the player's own lines live under: a JSON list of
/// [CustomQuickMessage]s, oldest first.
const quickCustomPrefsKey = 'quickCustomMessages';

/// How many lines of their own a player may keep. A quick message is one of a
/// few things a player says often; ten of their own beside the owner's ten is
/// already a list to scroll mid-hand.
const maxCustomQuickMessages = 10;

/// The longest line a player may save: the server's CHAT_MAX_LENGTH, so what
/// the list shows is what arrives — the server cuts anything longer.
const customQuickMessageMaxLength = 140;

/// A line of the player's own on the quick messages page.
class CustomQuickMessage {
  const CustomQuickMessage({required this.id, required this.text});

  /// Stable for the life of the line, whatever its place or text.
  final String id;

  /// What it says, as saved ([cleanQuickMessage]).
  final String text;

  Map<String, Object> toJson() => {'id': id, 'text': text};

  /// One saved line, or null for anything that is not one — a broken entry
  /// is dropped rather than half-read.
  static CustomQuickMessage? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final text = json['text'];
    if (id is! String || id.isEmpty || text is! String) return null;
    final clean = cleanQuickMessage(text);
    if (clean.isEmpty) return null;
    return CustomQuickMessage(id: id, text: clean);
  }
}

/// A line of the page as it is drawn: its [key] in the order, the words it
/// says, and which kind it is — [builtIn] is its index into
/// [Strings.quickMessages] for a set line, [customId] its id for one of the
/// player's own. Exactly one of the two is non-null.
typedef QuickEntry = ({
  String key,
  String text,
  int? builtIn,
  String? customId,
});

/// What became of a line the player tried to save.
enum QuickAddResult {
  /// Saved, at the top of the list.
  added,

  /// Nothing to say once cleaned: blank, or only spaces.
  empty,

  /// The list already says exactly that — a set line or their own.
  duplicate,

  /// They already keep [maxCustomQuickMessages] of their own.
  full,
}

/// The order key of the set line at [index] of [Strings.quickMessages].
String builtInQuickKey(int index) => '$index';

/// The order key of the player's own line [id].
String customQuickKey(String id) => 'c:$id';

/// The set line an order key names, or null when it names none.
int? builtInIndexOf(String key) {
  if (key.isEmpty || key.startsWith('c:')) return null;
  return int.tryParse(key);
}

/// The player's own line an order key names, or null when it names none.
String? customIdOf(String key) =>
    key.startsWith('c:') && key.length > 2 ? key.substring(2) : null;

/// The order to draw the page in, from what was [saved], for [builtInCount]
/// set lines and the player's own [customIds].
///
/// Whatever was saved is only a wish: a key naming a line that is not there (a
/// set line a later build dropped, one of their own they deleted) or named
/// twice is skipped, and every line the saved order does not name (a set line
/// a later build added, or nothing saved at all) takes its place after the
/// named ones — the set lines in the owner's order, then their own oldest
/// first. The result names every line exactly once.
List<String> normaliseQuickOrder(
  List<String> saved,
  int builtInCount,
  List<String> customIds,
) {
  final ids = customIds.toSet();
  // The key as the order keeps it, or null for one that names no line here.
  String? named(String key) {
    final i = builtInIndexOf(key);
    if (i != null) {
      return i >= 0 && i < builtInCount ? builtInQuickKey(i) : null;
    }
    final id = customIdOf(key);
    return id != null && ids.contains(id) ? customQuickKey(id) : null;
  }

  final seen = <String>{};
  final order = <String>[
    for (final key in saved)
      if (named(key) case final k? when seen.add(k)) k,
  ];
  for (var i = 0; i < builtInCount; i++) {
    if (seen.add(builtInQuickKey(i))) order.add(builtInQuickKey(i));
  }
  for (final id in customIds) {
    if (seen.add(customQuickKey(id))) order.add(customQuickKey(id));
  }
  return order;
}

/// [order] with the line at position [from] moved so that it ends at position
/// [to] — both as [ReorderableListView.onReorderItem] reports them, [to] being
/// where the line stands once it is out of its old place. A move to where it
/// already is changes nothing.
List<T> moveInQuickOrder<T>(List<T> order, int from, int to) {
  if (from < 0 || from >= order.length) return List.of(order);
  final next = List.of(order);
  final line = next.removeAt(from);
  next.insert(to.clamp(0, next.length), line);
  return next;
}

/// What was saved, read back: the keys it names, in order.
List<String> parseQuickOrder(List<String>? stored) => [
  for (final key in stored ?? const <String>[])
    if (key.isNotEmpty) key,
];

/// The player's own lines as saved, oldest first: anything that is not a list
/// of them — nothing saved, a broken write — reads as none, and a broken entry
/// or an id seen before is dropped.
List<CustomQuickMessage> decodeCustomQuickMessages(String? stored) {
  if (stored == null || stored.isEmpty) return const [];
  Object? json;
  try {
    json = jsonDecode(stored);
  } on FormatException {
    return const [];
  }
  if (json is! List) return const [];
  final ids = <String>{};
  return [
    for (final entry in json)
      if (CustomQuickMessage.fromJson(entry) case final line?)
        if (ids.add(line.id)) line,
  ];
}

/// The player's own lines as they are written to SharedPreferences.
String encodeCustomQuickMessages(List<CustomQuickMessage> lines) =>
    jsonEncode([for (final line in lines) line.toJson()]);

/// [raw] as a line the player can keep: what the server would make of it —
/// every control or format character a space, runs of spaces one, the ends
/// trimmed (`SanitizeChat`, go-server/internal/game/chat.go) — cut to
/// [customQuickMessageMaxLength]. Saved already clean, a line shows exactly
/// what the table will read.
String cleanQuickMessage(String raw) {
  final clean = raw
      .replaceAll(RegExp(r'\p{C}', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+', unicode: true), ' ')
      .trim();
  if (clean.length <= customQuickMessageMaxLength) return clean;
  // Counted in UTF-16 units, as the server counts; never between the two
  // halves of one character.
  var end = customQuickMessageMaxLength;
  final last = clean.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return clean.substring(0, end).trimRight();
}
