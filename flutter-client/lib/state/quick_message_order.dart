/// The order the chat drawer's quick messages stand in, as the player last
/// arranged them (owner, 25 Sep 2026: "make sure user can drag and reorder the
/// quick message in UI … save that order in UI only").
///
/// An order is a list of indices into [Strings.quickMessages] — the lines'
/// places in the owner's list, not their text — so one arrangement holds in
/// every language and survives a translation being reworded. It is kept on
/// this phone alone (SharedPreferences, [prefsKey]); nothing about it reaches
/// the server, and a line goes out as the same words whatever its place.
///
/// Pure functions, so the rules are tested without a widget: GameState keeps
/// what was saved and asks [normaliseQuickOrder] for the order to draw.
library;

/// The SharedPreferences key the saved order lives under: the indices as
/// decimal strings, in the order the player put them.
const quickOrderPrefsKey = 'quickMessageOrder';

/// The order to draw [count] quick messages in, from what was [saved].
///
/// Whatever was saved is only a wish: an index out of range (a line a later
/// build dropped) or repeated is skipped, and any line the saved order does not
/// name (a line a later build added, or nothing saved at all) takes its place
/// after the named ones, in the owner's order. The result is always a
/// permutation of `0 … count-1`.
List<int> normaliseQuickOrder(List<int> saved, int count) {
  final seen = <int>{};
  final order = <int>[
    for (final i in saved)
      if (i >= 0 && i < count && seen.add(i)) i,
  ];
  for (var i = 0; i < count; i++) {
    if (!seen.contains(i)) order.add(i);
  }
  return order;
}

/// [order] with the line at position [from] moved so that it ends at position
/// [to] — both as [ReorderableListView.onReorderItem] reports them, [to] being
/// where the line stands once it is out of its old place. A move to where it
/// already is changes nothing.
List<int> moveInQuickOrder(List<int> order, int from, int to) {
  if (from < 0 || from >= order.length) return List.of(order);
  final next = List.of(order);
  final line = next.removeAt(from);
  next.insert(to.clamp(0, next.length), line);
  return next;
}

/// What was saved, read back: the indices it names, in order. Anything that
/// is not a whole number is dropped rather than trusted.
List<int> parseQuickOrder(List<String>? stored) => [
  for (final s in stored ?? const <String>[])
    if (int.tryParse(s) case final int i) i,
];

/// [order] as it is written to SharedPreferences.
List<String> encodeQuickOrder(List<int> order) => [for (final i in order) '$i'];
