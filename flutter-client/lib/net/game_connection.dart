import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:uuid/uuid.dart';

import '../models/dtos.dart';

/// A hand's reveal or its end, as `game:showdown` and `game:handEnded` carry
/// them. `reason` is the server's (`missile` for a hand a missile ended);
/// empty when it sent none.
typedef ShowdownNews = ({
  List<Reveal> reveals,
  String result,
  String? winnerId,
  String winnerName,
  int pot,
  int nextHandAt,
  String reason,
});

/// A variation window closing, as the room hears it: `game:variationSelected`,
/// and the `variation`/`turnUp` a variation table's `game:showdown` and
/// `game:handEnded` repeat. [selectedBy] is a [VariationSelectedBy] value, or
/// empty on the showdown's copy, which does not say. [turnUp] is the card
/// turned up from the deck ("9h"), sent only under Joker and Hukam.
typedef VariationNews = ({String variation, String selectedBy, String? turnUp});

/// The live half of the server: one Socket.IO connection carrying the whole
/// game.
///
/// Every rule lives on the server, so this class only sends intent and reports
/// what comes back. It never decides whether a move is legal, what a bet may
/// be, or who won — and it never sees a card the server did not choose to send.
class GameConnection {
  GameConnection(this.baseUrl);

  final String baseUrl;
  io.Socket? _socket;
  static const _uuid = Uuid();

  final _state = StreamController<RoomState>.broadcast();
  final _session =
      StreamController<
        ({User user, GameConfig config, ResumeHint? resume})
      >.broadcast();
  final _cards = StreamController<List<String>>.broadcast();
  final _showdown = StreamController<ShowdownNews>.broadcast();
  final _sideshowAsked = StreamController<PendingSideshow>.broadcast();
  final _sideshowReveal = StreamController<SideshowReveal>.broadcast();
  final _sideshowDone =
      StreamController<
        ({
          String fromUserId,
          String toUserId,
          bool accepted,
          String reason,
          String? packedUserId,
        })
      >.broadcast();
  final _variationSelecting = StreamController<VariationState>.broadcast();
  final _variationSelected = StreamController<VariationNews>.broadcast();
  final _variationAtShowdown = StreamController<VariationNews>.broadcast();
  final _action =
      StreamController<
        ({String userId, String action, String? reason})
      >.broadcast();
  final _chat = StreamController<ChatMessage>.broadcast();
  final _chatHistory = StreamController<List<ChatMessage>>.broadcast();
  final _errors =
      StreamController<({String? code, String message})>.broadcast();
  final _left = StreamController<void>.broadcast();
  final _kicked =
      StreamController<({String reason, String message})>.broadcast();
  final _connected = StreamController<bool>.broadcast();

  /// A full table snapshot, already redacted for this viewer.
  Stream<RoomState> get onState => _state.stream;

  /// Who this is and how the game is configured; `resume` names a table to go
  /// straight back to when a held seat has already lapsed.
  Stream<({User user, GameConfig config, ResumeHint? resume})> get onSession =>
      _session.stream;

  /// This player's own three cards, sent only once they have looked.
  Stream<List<String>> get onCards => _cards.stream;
  Stream<ShowdownNews> get onShowdown => _showdown.stream;

  /// Somebody asked for a sideshow. Everyone at the table hears this — it is
  /// what drives the animation between the two seats — but it carries no cards.
  Stream<PendingSideshow> get onSideshowAsked => _sideshowAsked.stream;

  /// The two hands in an accepted sideshow. The server sends this only to the
  /// two players involved, so simply receiving it means the viewer is one.
  Stream<SideshowReveal> get onSideshowReveal => _sideshowReveal.stream;

  /// How it ended, for the whole table: accepted or not, and who packed.
  Stream<
    ({
      String fromUserId,
      String toUserId,
      bool accepted,
      String reason,
      String? packedUserId,
    })
  >
  get onSideshowDone => _sideshowDone.stream;

  /// A variation table's window opening: who is choosing and until when.
  /// Public, and only a repeat of what the snapshot that follows says — a
  /// client that reconnects mid-window never hears it and loses nothing.
  Stream<VariationState> get onVariationSelecting => _variationSelecting.stream;

  /// The window closing: what was chosen, and whether a player chose it.
  /// Again only a repeat of the snapshot, which is the truth.
  Stream<VariationNews> get onVariationSelected => _variationSelected.stream;

  /// The variation a finished hand was played under, as its `game:showdown`
  /// and `game:handEnded` name it. Its own stream rather than two more fields
  /// on [ShowdownNews]: a seen or blind table's showdown carries neither, and
  /// the celebration has no use for them.
  Stream<VariationNews> get onVariationAtShowdown =>
      _variationAtShowdown.stream;

  /// A move somebody made, as the room hears it. The table's state already
  /// says what each move did, so the client reads this only for what a
  /// snapshot cannot say: why a player packed. A pack with reason `sideshow`
  /// that arrives while no sideshow was pending is a Force Sideshow's loser,
  /// and it lands before the snapshot that folds them.
  Stream<({String userId, String action, String? reason})> get onAction =>
      _action.stream;
  Stream<ChatMessage> get onChat => _chat.stream;
  Stream<List<ChatMessage>> get onChatHistory => _chatHistory.stream;

  /// A refusal or a failure. `code` is the server's snake_case code when it
  /// sent one: its messages are English by design, so the client localises
  /// by code and falls back to `message` for anything it has no words for.
  Stream<({String? code, String message})> get onError => _errors.stream;
  Stream<void> get onLeft => _left.stream;

  /// The table showed this player out: the server's reason code (`idle`,
  /// `insufficient_chips`) and its English sentence, for a reason the client
  /// has no words of its own for.
  Stream<({String reason, String message})> get onKicked => _kicked.stream;
  Stream<bool> get onConnected => _connected.stream;

  bool get isConnected => _socket?.connected ?? false;

  /// The code a move gets when it is refused because the socket is down.
  static const notConnected = 'not_connected';

  void connect(String token) {
    disconnect();

    final socket = io.io(
      baseUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .enableReconnection()
          .setReconnectionDelay(800)
          .build(),
    );
    _socket = socket;

    socket.onConnect((_) => _connected.add(true));
    socket.onDisconnect((_) {
      // The library keeps what was emitted while it was down and sends it all
      // on reconnect, so a Chaal tapped into a dead connection reached the
      // server 77 seconds later, for a turn long gone (QA PIX-1, 14 Sep 2026)
      // — had it been this player's turn again, it would have bet for them.
      // Nothing waits: whatever made it into the buffer is dropped here, and
      // [_emit] and [request] refuse while the socket is down.
      socket.sendBuffer.clear();
      _connected.add(false);
    });
    socket.onConnectError(
      (e) =>
          _errors.add((code: null, message: 'Could not reach the table: $e')),
    );

    socket.on('session:ready', (data) {
      final j = _map(data);
      _session.add((
        user: User.fromJson(_map(j['user'])),
        config: j['config'] is Map
            ? GameConfig.fromJson(_map(j['config']))
            : GameConfig.fallback,
        resume: j['resume'] is Map
            ? ResumeHint.fromJson(_map(j['resume']))
            : null,
      ));
    });

    // room:joined and room:state carry the same shape; the first is this
    // player sitting down, the second is anything changing afterwards.
    void state(dynamic data) => _state.add(RoomState.fromJson(_map(data)));
    socket.on('room:joined', state);
    socket.on('room:state', state);
    socket.on('room:moved', (data) {
      // Two near-empty tables were merged (requirement 24); the snapshot for
      // the new table follows immediately.
      final j = _map(data);
      if (j['state'] is Map) _state.add(RoomState.fromJson(_map(j['state'])));
    });

    socket.on('room:left', (_) => _left.add(null));
    socket.on('room:kicked', (data) {
      final j = _map(data);
      _kicked.add((
        reason: '${j['reason'] ?? ''}',
        message: '${j['message'] ?? 'You were removed from the table.'}',
      ));
    });
    socket.on('room:closed', (_) => _left.add(null));

    socket.on('player:cards', (data) {
      final j = _map(data);
      _cards.add((j['cards'] as List? ?? []).map((e) => '$e').toList());
    });

    // The showdown is the reveal; the hand ending is who took it and for how
    // much. Both feed the same celebration.
    socket.on('game:showdown', (data) => _emitShowdown(data, null));
    socket.on('game:handEnded', (data) {
      final j = _map(data);
      final winner = '${j['winnerName'] ?? ''}';
      final pot = (j['pot'] as num?)?.toInt() ?? 0;
      _emitShowdown(
        data,
        winner.isEmpty ? null : '$winner won ${_grouped(pot)}',
      );
    });

    socket.on(
      'game:sideshowRequested',
      (data) => _sideshowAsked.add(PendingSideshow.fromJson(_map(data))),
    );
    socket.on('game:sideshowReveal', (data) {
      final j = _map(data);
      if (j['reveal'] is Map) {
        _sideshowReveal.add(SideshowReveal.fromJson(_map(j['reveal'])));
      }
    });
    socket.on('game:sideshowResolved', (data) {
      final j = _map(data);
      _sideshowDone.add((
        fromUserId: '${j['fromUserId'] ?? ''}',
        toUserId: '${j['toUserId'] ?? ''}',
        accepted: j['accepted'] == true,
        reason: '${j['reason'] ?? ''}',
        packedUserId: j['packedUserId'] as String?,
      ));
    });

    socket.on('game:variationSelecting', (data) {
      // The event's fields are the snapshot block's own, minus the three that
      // say the window is open — which receiving it already does.
      final j = _map(data);
      _variationSelecting.add(
        VariationState.fromJson({...j, 'selecting': true}),
      );
    });
    socket.on('game:variationSelected', (data) {
      final news = _variationNews(_map(data));
      if (news != null) _variationSelected.add(news);
    });

    socket.on('game:action', (data) {
      final j = _map(data);
      _action.add((
        userId: '${j['userId'] ?? ''}',
        action: '${j['action'] ?? ''}',
        reason: j['reason'] is String ? j['reason'] as String : null,
      ));
    });

    socket.on(
      'chat:message',
      (data) => _chat.add(ChatMessage.fromJson(_map(data))),
    );
    socket.on('chat:history', (data) {
      final j = _map(data);
      _chatHistory.add(
        (j['messages'] as List? ?? [])
            .map((e) => ChatMessage.fromJson(_map(e)))
            .toList(),
      );
    });

    socket.on('game:error', (data) {
      final j = _map(data);
      _errors.add((code: _code(j), message: '${j['message']}'));
    });
    socket.on(
      'session:replaced',
      (data) => _errors.add((
        code: null,
        message: '${_map(data)['message'] ?? 'Signed in elsewhere'}',
      )),
    );
  }

  /// What a payload says of the hand's variation, or null when it names none
  /// (every seen and blind table, and a hand that ended before one was chosen).
  static VariationNews? _variationNews(Map<String, dynamic> j) {
    final variation = j['variation'];
    if (variation is! String || variation.isEmpty) return null;
    return (
      variation: variation,
      selectedBy: j['selectedBy'] is String ? j['selectedBy'] as String : '',
      turnUp: j['turnUp'] is String ? j['turnUp'] as String : null,
    );
  }

  void _emitShowdown(dynamic data, String? result) {
    final j = _map(data);
    // Before the reveal it belongs to, so the hands turn over already knowing
    // what they were played under.
    final played = _variationNews(j);
    if (played != null) _variationAtShowdown.add(played);
    final reveals = (j['reveals'] as List? ?? [])
        .map((e) => Reveal.fromJson(_map(e)))
        .toList();
    if (reveals.isEmpty && result == null) return;

    _showdown.add((
      reveals: reveals,
      result: result ?? '',
      winnerId: j['winnerId'] as String?,
      winnerName: '${j['winnerName'] ?? ''}',
      pot: (j['pot'] as num?)?.toInt() ?? 0,
      // Only the hand-ended frame carries this; the reveal that precedes it
      // does not, and 0 means "not stated".
      nextHandAt: (j['nextHandAt'] as num?)?.toInt() ?? 0,
      reason: j['reason'] is String ? j['reason'] as String : '',
    ));
  }

  // ------------------------------------------------------------ intent

  /// Sits the player at any table with this stake and category, opening one if
  /// there is nothing suitable.
  void quickJoin(int bootAmount, String category) =>
      _emit('room:quickJoin', {'bootAmount': bootAmount, 'category': category});

  /// Opens a private table. The boot is fixed server-side (requirement 22), so
  /// nothing is chosen here.
  void createPrivate(String category) =>
      _emit('room:create', {'isPrivate': true, 'category': category});

  void joinByCode(String code) => _emit('room:joinCode', {'code': code});

  void leave() => _emit('room:leave', const {});

  /// Sends a move. [amount] is what the stepper picked; the server validates it
  /// against the ladder it computes itself, so a tampered client gains nothing.
  ///
  /// Every move carries a fresh [actionId]. The server writes it onto the
  /// ledger row for the bet, where it is unique — so if this request is ever
  /// sent twice (a retry after a lost ack, a double tap) the second copy is
  /// refused rather than charged again.
  void act(String action, {int? amount}) => _emit('game:action', {
    'action': action,
    'amount': ?amount,
    'actionId': _uuid.v4(),
  });

  /// Forces a sideshow with the player on the viewer's right, and waits for
  /// the answer (owner, 13 Sep 2026).
  ///
  /// Unlike [act] this hands the ack back, because the ack is where the
  /// server says how many hammers are left: `{ok: true, action, toUserId,
  /// packedUserId, hammers}`, or `{ok: false, code, message}`.
  ///
  /// The caller chooses [actionId] and must send the SAME one again when it
  /// retries: the server keys the hammer it spends on it, so a retry after a
  /// lost answer resolves the sideshow without charging a second hammer. A
  /// fresh id per retry would be charged again.
  Future<Map<String, dynamic>> forceSideshow(String actionId) => request(
    'game:action',
    {'action': GameAction.forceSideshow, 'actionId': actionId},
  );

  /// Fires a missile, and waits for the answer (owner, 14 Sep 2026).
  ///
  /// The ack is `{ok: true, action: "missile", missiles}` — the missiles left
  /// — or `{ok: false, code, message}`. Like [forceSideshow], the caller
  /// chooses [actionId] and sends the SAME one on a retry of that attempt, so
  /// a retry after a lost answer is not charged a second missile.
  Future<Map<String, dynamic>> fireMissile(String actionId) => request(
    'game:action',
    {'action': GameAction.missile, 'actionId': actionId},
  );

  /// Answers a sideshow. Only the player who was asked may; anyone else gets a
  /// refusal in the ack.
  void respondToSideshow(bool accept) =>
      _emit('game:sideshowRespond', {'accept': accept});

  /// Chooses the variation this hand is played under. Only the player the
  /// window is open for may, and only while it is open: anyone else, a second
  /// tap, or a tap the server's clock beat gets a refusal in the ack
  /// (`not_selecting`, `variation_already_selected`, `variation_expired`).
  /// No player id is sent — the server takes it from the socket.
  ///
  /// Awaited, unlike a bet: the picker keeps its keys dark until it knows
  /// whether the choice stood, and only the ack can say so.
  Future<Map<String, dynamic>> selectVariation(String variation) =>
      request('game:selectVariation', {'variation': variation});

  void requestCards() => _emit('player:requestCards', const {});

  void sendChat(String text) => _emit('chat:message', {'text': text});

  /// Sends an event and waits for the server's acknowledgement.
  ///
  /// Every gameplay handler is wrapped in the server's `guard`, which always
  /// acks with `{ok: true, ...}` or `{ok: false, code, message}` — so a refusal
  /// arrives as a value, not as a thrown error.
  Future<Map<String, dynamic>> request(
    String event,
    Map<String, dynamic> payload,
  ) async {
    final socket = _socket;
    if (socket == null || !socket.connected) {
      return {'ok': false, 'code': notConnected, 'message': 'Not connected'};
    }

    final done = Completer<Map<String, dynamic>>();
    socket.emitWithAck(
      event,
      payload,
      ack: (dynamic response) {
        if (!done.isCompleted) done.complete(_map(response));
      },
    );

    return done.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => {'ok': false, 'message': 'The server did not answer'},
    );
  }

  void _emit(String event, Map<String, dynamic> payload) {
    final socket = _socket;
    if (socket == null) return;
    // Refused now rather than buffered for later (see onDisconnect).
    if (!socket.connected) {
      _errors.add((code: notConnected, message: 'Not connected'));
      return;
    }

    // Every gameplay event is acknowledged, and a refusal comes back in the
    // ack rather than as a thrown error.
    socket.emitWithAck(
      event,
      payload,
      ack: (dynamic response) {
        final j = _map(response);
        if (j['ok'] == false) {
          _errors.add((
            code: _code(j),
            message: '${j['message'] ?? 'That move was refused'}',
          ));
        }
      },
    );
  }

  /// The refusal's code, or null when the payload carries none.
  static String? _code(Map<String, dynamic> j) =>
      j['code'] is String ? j['code'] as String : null;

  void disconnect() {
    _socket?.dispose();
    _socket = null;
  }

  void dispose() {
    disconnect();
    _state.close();
    _session.close();
    _cards.close();
    _showdown.close();
    _sideshowAsked.close();
    _sideshowReveal.close();
    _sideshowDone.close();
    _variationSelecting.close();
    _variationSelected.close();
    _variationAtShowdown.close();
    _action.close();
    _chat.close();
    _chatHistory.close();
    _errors.close();
    _left.close();
    _kicked.close();
    _connected.close();
  }

  static Map<String, dynamic> _map(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  static String _grouped(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }
}
