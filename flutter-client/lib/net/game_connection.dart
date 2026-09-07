import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

import '../models/dtos.dart';

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

  final _state = StreamController<RoomState>.broadcast();
  final _session = StreamController<({User user, GameConfig config})>.broadcast();
  final _cards = StreamController<List<String>>.broadcast();
  final _showdown = StreamController<
      ({
        List<Reveal> reveals,
        String result,
        String? winnerId,
        String winnerName,
        int pot,
      })>.broadcast();
  final _chat = StreamController<ChatMessage>.broadcast();
  final _chatHistory = StreamController<List<ChatMessage>>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _left = StreamController<void>.broadcast();
  final _kicked = StreamController<String>.broadcast();
  final _connected = StreamController<bool>.broadcast();

  /// A full table snapshot, already redacted for this viewer.
  Stream<RoomState> get onState => _state.stream;
  Stream<({User user, GameConfig config})> get onSession => _session.stream;

  /// This player's own three cards, sent only once they have looked.
  Stream<List<String>> get onCards => _cards.stream;
  Stream<
      ({
        List<Reveal> reveals,
        String result,
        String? winnerId,
        String winnerName,
        int pot,
      })> get onShowdown => _showdown.stream;
  Stream<ChatMessage> get onChat => _chat.stream;
  Stream<List<ChatMessage>> get onChatHistory => _chatHistory.stream;
  Stream<String> get onError => _errors.stream;
  Stream<void> get onLeft => _left.stream;

  /// The table showed this player out, with the reason to tell them.
  Stream<String> get onKicked => _kicked.stream;
  Stream<bool> get onConnected => _connected.stream;

  bool get isConnected => _socket?.connected ?? false;

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
    socket.onDisconnect((_) => _connected.add(false));
    socket.onConnectError((e) => _errors.add('Could not reach the table: $e'));

    socket.on('session:ready', (data) {
      final j = _map(data);
      _session.add((
        user: User.fromJson(_map(j['user'])),
        config: j['config'] is Map
            ? GameConfig.fromJson(_map(j['config']))
            : GameConfig.fallback,
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
      _kicked.add('${j['message'] ?? 'You were removed from the table.'}');
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

    socket.on('chat:message', (data) => _chat.add(ChatMessage.fromJson(_map(data))));
    socket.on('chat:history', (data) {
      final j = _map(data);
      _chatHistory.add((j['messages'] as List? ?? [])
          .map((e) => ChatMessage.fromJson(_map(e)))
          .toList());
    });

    socket.on('game:error', (data) => _errors.add('${_map(data)['message']}'));
    socket.on('session:replaced',
        (data) => _errors.add('${_map(data)['message'] ?? 'Signed in elsewhere'}'));
  }

  void _emitShowdown(dynamic data, String? result) {
    final j = _map(data);
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
  void act(String action, {int? amount}) => _emit('game:action', {
        'action': action,
        'amount': ?amount,
      });

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
    if (socket == null) return {'ok': false, 'message': 'Not connected'};

    final done = Completer<Map<String, dynamic>>();
    socket.emitWithAck(event, payload, ack: (dynamic response) {
      if (!done.isCompleted) done.complete(_map(response));
    });

    return done.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => {'ok': false, 'message': 'The server did not answer'},
    );
  }

  void _emit(String event, Map<String, dynamic> payload) {
    final socket = _socket;
    if (socket == null) return;

    // Every gameplay event is acknowledged, and a refusal comes back in the
    // ack rather than as a thrown error.
    socket.emitWithAck(event, payload, ack: (dynamic response) {
      final j = _map(response);
      if (j['ok'] == false) _errors.add('${j['message'] ?? 'That move was refused'}');
    });
  }

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
