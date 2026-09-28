import 'package:flutter/foundation.dart';

import '../models/dtos.dart';

/// The countdown before a deal, as this phone keeps it (owner, 29 Sep 2026:
/// "whenever Game starts in any game table, instead of showing text
/// "Starting game .." show this count Down animation 3,2,1 … and when
/// countdown finishes then distribute card").
///
/// The server says when it will deal (`startsAt`) and, since this build, how
/// long that is from the moment it sent the snapshot (`startsInMs`). The
/// countdown is anchored to the moment the snapshot ARRIVED plus that time
/// left, never to `startsAt` against the phone's own clock: a phone set a
/// minute wrong still counts to the deal. Arriving one network trip late, it
/// also ends one trip after the server deals — which is when the deal's own
/// snapshot arrives, one trip late too. A server that sends no `startsInMs`
/// is counted to `startsAt` on the phone's clock, as the table always was.
///
/// A countdown is ONE deal: its identity is the table and the server's
/// `startsAt`. Every later snapshot of the same deal (a player joining, a
/// picture laid, a reconnect) re-estimates the moment and keeps the EARLIER
/// estimate — each is the true moment plus that snapshot's delay, so the
/// earliest is the best — and never restarts the countdown from 3. A new
/// `startsAt` (a countdown cancelled and started again) is a new countdown.
@immutable
class StartCountdown {
  const StartCountdown({
    required this.roomId,
    required this.startsAt,
    required this.dealAt,
  });

  /// How long the countdown the table shows lasts: "3, 2, 1". The server's
  /// own figure is the same (game.StartCountdown); a window longer than this
  /// (the winner's celebration after a hand) shows the countdown in its last
  /// three seconds only.
  static const Duration length = Duration(seconds: 3);
  static final int lengthMs = length.inMilliseconds;

  /// The clock the countdown is kept on — this phone's epoch milliseconds,
  /// read by GameState as a snapshot arrives and by the felt every frame. The
  /// tests set it to walk the countdown frame by frame.
  static int Function() clock = _wallClock;
  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// The table, and the deal as the server named it: together, which
  /// countdown this is.
  final String roomId;
  final int startsAt;

  /// When the deal is expected, in this phone's epoch milliseconds.
  final int dealAt;

  /// Milliseconds left until the deal at [nowMs]: negative once it is due.
  int leftMs(int nowMs) => dealAt - nowMs;

  /// Whether the countdown is on the table at [nowMs]: from [length] before
  /// the deal until the deal's snapshot takes the table out of `starting`
  /// (the countdown clears then). Before that the window is the last hand's
  /// celebration, which the countdown never runs over.
  bool showingAt(int nowMs) => leftMs(nowMs) <= lengthMs;

  /// The number showing at [nowMs]: 3 in the first second, then 2, then 1.
  static int numberFor(int leftMs) =>
      ((leftMs + 999) ~/ 1000).clamp(1, length.inSeconds);

  /// How far through the countdown [leftMs] is: 0 as "3" arrives, 1 at the
  /// deal. A countdown joined late (a reconnect, a snapshot delayed) starts
  /// part-way — at "2" or "1" — and is never replayed from 3.
  static double progressFor(int leftMs) =>
      (1 - leftMs / lengthMs).clamp(0.0, 1.0);

  /// What a snapshot [s], received at [receivedAtMs], makes of the countdown
  /// [held]: null when the table is not counting down; the same countdown,
  /// with the earlier of the two estimates, when it is the same deal; a new
  /// one otherwise.
  static StartCountdown? follow(
    StartCountdown? held,
    RoomState s, {
    required int receivedAtMs,
  }) {
    if (s.state != TableState.starting || s.startsAt <= 0) return null;
    final estimate = switch (s.startsInMs) {
      final left? => receivedAtMs + left,
      // A server that predates `startsInMs`: its absolute moment, on this
      // phone's clock — what the table always did.
      null => s.startsAt,
    };
    if (held != null &&
        held.roomId == s.roomId &&
        held.startsAt == s.startsAt) {
      return estimate < held.dealAt
          ? StartCountdown(
              roomId: s.roomId,
              startsAt: s.startsAt,
              dealAt: estimate,
            )
          : held;
    }
    return StartCountdown(
      roomId: s.roomId,
      startsAt: s.startsAt,
      dealAt: estimate,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StartCountdown &&
      other.roomId == roomId &&
      other.startsAt == startsAt &&
      other.dealAt == dealAt;

  @override
  int get hashCode => Object.hash(roomId, startsAt, dealAt);

  @override
  String toString() => 'StartCountdown($roomId, $startsAt, dealAt: $dealAt)';
}
