import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:uuid/uuid.dart';

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
  static const _uuid = Uuid();

  /// The token and Socket.IO path the live socket was opened with, kept so a
  /// `session:redirect` can open the next one the same way on another path.
  String? _token;
  String? _path;

  /// A table code a redirect asked us to join once we are on the right worker.
  /// Consumed by the first `session:ready` that follows, and only that one.
  String? _joinAfterRedirect;

  /// Consecutive failures to open a socket on a remembered worker path. The
  /// path came from the server, but a worker can be gone by the time it is
  /// tried again; after a couple of misses the default door is used instead.
  int _pathFailures = 0;
  static const _pathFailuresBeforeFallback = 2;

  /// The worker path that was just given up on, and when. A redirect that
  /// points straight back at it — a worker mid-restart whose registry rows
  /// have not gone yet — is followed after a pause rather than at once, so
  /// the worker has a moment to come back (or to withdraw its rows).
  String? _lastFailedPath;
  DateTime? _lastFailedAt;
  static const _retryFailedPathAfter = Duration(seconds: 2);

  /// Redirects followed without a `session:ready` in between. Two workers
  /// each pointing at the other would otherwise bounce us forever in silence.
  int _redirectsInARow = 0;
  static const _maxRedirectsInARow = 3;

  final _state = StreamController<RoomState>.broadcast();
  final _session = StreamController<
      ({User user, GameConfig config, ResumeHint? resume, WorkerHint? worker})>.broadcast();
  final _redirect = StreamController<
      ({int worker, String path, String reason, String? joinCode})>.broadcast();
  final _cards = StreamController<List<String>>.broadcast();
  final _showdown = StreamController<
      ({
        List<Reveal> reveals,
        String result,
        String? winnerId,
        String winnerName,
        int pot,
        int nextHandAt,
      })>.broadcast();
  final _sideshowAsked = StreamController<PendingSideshow>.broadcast();
  final _sideshowReveal = StreamController<SideshowReveal>.broadcast();
  final _sideshowDone = StreamController<
      ({String fromUserId, String toUserId, bool accepted, String reason, String? packedUserId})>.broadcast();
  final _chat = StreamController<ChatMessage>.broadcast();
  final _chatHistory = StreamController<List<ChatMessage>>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _left = StreamController<void>.broadcast();
  final _kicked = StreamController<String>.broadcast();
  final _connected = StreamController<bool>.broadcast();

  /// A full table snapshot, already redacted for this viewer.
  Stream<RoomState> get onState => _state.stream;
  /// Who this is and how the game is configured; `resume` names a table to go
  /// straight back to when a held seat has already lapsed; `worker` says which
  /// server process this is and the path that reaches it directly.
  Stream<({User user, GameConfig config, ResumeHint? resume, WorkerHint? worker})>
      get onSession => _session.stream;

  /// The server sent us to another worker — the one holding our seat, or the
  /// table whose code we typed — and this connection is being reopened there.
  /// It comes *instead of* `session:ready`, never after it, so whatever was
  /// waiting on the session keeps waiting; the next `session:ready` is the
  /// real one.
  Stream<({int worker, String path, String reason, String? joinCode})> get onRedirect =>
      _redirect.stream;

  /// The Socket.IO path the live socket uses, or null for the server default.
  String? get path => _path;

  /// This player's own three cards, sent only once they have looked.
  Stream<List<String>> get onCards => _cards.stream;
  Stream<
      ({
        List<Reveal> reveals,
        String result,
        String? winnerId,
        String winnerName,
        int pot,
        int nextHandAt,
      })> get onShowdown => _showdown.stream;
  /// Somebody asked for a sideshow. Everyone at the table hears this — it is
  /// what drives the animation between the two seats — but it carries no cards.
  Stream<PendingSideshow> get onSideshowAsked => _sideshowAsked.stream;

  /// The two hands in an accepted sideshow. The server sends this only to the
  /// two players involved, so simply receiving it means the viewer is one.
  Stream<SideshowReveal> get onSideshowReveal => _sideshowReveal.stream;

  /// How it ended, for the whole table: accepted or not, and who packed.
  Stream<
      ({String fromUserId, String toUserId, bool accepted, String reason, String? packedUserId})>
      get onSideshowDone => _sideshowDone.stream;
  Stream<ChatMessage> get onChat => _chat.stream;
  Stream<List<ChatMessage>> get onChatHistory => _chatHistory.stream;
  Stream<String> get onError => _errors.stream;
  Stream<void> get onLeft => _left.stream;

  /// The table showed this player out, with the reason to tell them.
  Stream<String> get onKicked => _kicked.stream;
  Stream<bool> get onConnected => _connected.stream;

  bool get isConnected => _socket?.connected ?? false;

  /// The Socket.IO options every connection is opened with.
  ///
  /// `forceNew` is load-bearing: socket_io_client keeps one `Manager` per
  /// scheme://host:port and, because [baseUrl] has no path, reuses it for
  /// every later `io()` call — with the `path` and `auth` it was *first* built
  /// with. Without `forceNew` a `session:redirect` to `/w2/socket.io` would
  /// silently reconnect on the old path, and a sign-in as another account
  /// would reuse the first token. (`disableMultiplex()` only removes the key;
  /// it does not set `multiplex: false`.)
  static Map<String, dynamic> buildOptions(String token, {String? path}) {
    final options = io.OptionBuilder()
        .setTransports(['websocket'])
        .setAuth({'token': token})
        .enableForceNew()
        .enableReconnection()
        .setReconnectionDelay(800);
    if (path != null && path.isNotEmpty) options.setPath(path);
    return options.build();
  }

  /// Opens the socket. [path] is the Socket.IO path of the worker to reach —
  /// the one remembered from the last `session:ready` — or null for the
  /// server's default, which lands on any worker and lets it redirect us.
  void connect(String token, {String? path}) {
    // Only the socket goes; a join left pending by a redirect is for the
    // connection being opened here.
    _closeSocket();
    _token = token;
    _path = (path == null || path.isEmpty) ? null : path;
    _pathFailures = 0;

    final chosenPath = _path;
    final socket = io.io(baseUrl, buildOptions(token, path: chosenPath));
    _socket = socket;

    socket.onConnect((_) {
      _pathFailures = 0;
      _connected.add(true);
    });
    socket.onDisconnect((_) => _connected.add(false));
    socket.onConnectError((e) {
      _errors.add('Could not reach the table: $e');
      // A remembered worker path that keeps failing — the worker is gone, or
      // the deployment changed — must not lock the player out. The default
      // path reaches whichever worker is up, and that one sends us on. The
      // fallback is a fresh start for the loop detector too: a redirect back
      // to this path is a new attempt, not the same bounce again.
      if (chosenPath != null && ++_pathFailures >= _pathFailuresBeforeFallback) {
        _lastFailedPath = chosenPath;
        _lastFailedAt = DateTime.now();
        _redirectsInARow = 0;
        _reopen(socket, path: null);
      }
    });

    socket.on('session:ready', (data) {
      _redirectsInARow = 0;
      final j = _map(data);
      _session.add((
        user: User.fromJson(_map(j['user'])),
        config: j['config'] is Map
            ? GameConfig.fromJson(_map(j['config']))
            : GameConfig.fallback,
        resume: j['resume'] is Map ? ResumeHint.fromJson(_map(j['resume'])) : null,
        worker: j['worker'] is Map ? WorkerHint.fromJson(_map(j['worker'])) : null,
      ));

      // A redirect that named a table: now that we are on its worker, sit
      // down at it. Once — a later reconnect must not re-join a table we
      // have since left.
      final pending = _joinAfterRedirect;
      _joinAfterRedirect = null;
      if (pending != null) joinByCode(pending);
    });

    // The server has our seat, or the table we asked for, on another worker
    // process. It hangs up straight after saying so; the same token opens the
    // door it named, and the `session:ready` that follows is the real one.
    socket.on('session:redirect', (data) {
      final j = _map(data);
      final target = '${j['path'] ?? ''}';
      if (target.isEmpty) return;
      if (++_redirectsInARow > _maxRedirectsInARow) {
        _errors.add('The servers could not agree where your table is. Try again.');
        return;
      }
      final joinCode = j['joinCode'];
      _joinAfterRedirect = joinCode is String && joinCode.isNotEmpty ? joinCode : null;
      _redirect.add((
        worker: (j['worker'] as num?)?.toInt() ?? 0,
        path: target,
        reason: '${j['reason'] ?? ''}',
        joinCode: _joinAfterRedirect,
      ));
      _reopen(socket, path: target, after: _pauseBefore(target));
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

    socket.on('game:sideshowRequested',
        (data) => _sideshowAsked.add(PendingSideshow.fromJson(_map(data))));
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

  /// How long to wait before following a redirect to [path]: a couple of
  /// seconds if that very path just failed us, otherwise no time at all.
  Duration _pauseBefore(String path) {
    final failedAt = _lastFailedAt;
    if (path != _lastFailedPath || failedAt == null) return Duration.zero;
    final sinceFailure = DateTime.now().difference(failedAt);
    if (sinceFailure >= _retryFailedPathAfter) return Duration.zero;
    return _retryFailedPathAfter - sinceFailure;
  }

  /// Closes [current] and opens a fresh socket on [path] with the same token.
  ///
  /// Deferred at least a tick: this is called from inside the old socket's own
  /// event handler, and tearing the transport down under the packet being read
  /// is not something to lean on. The check that [current] is still the live
  /// socket means a sign-out in the meantime wins.
  void _reopen(io.Socket current, {required String? path, Duration after = Duration.zero}) {
    void go() {
      final token = _token;
      if (token == null || _socket != current) return;
      connect(token, path: path);
    }
    if (after <= Duration.zero) {
      Timer.run(go);
    } else {
      Timer(after, go);
    }
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
      // Only the hand-ended frame carries this; the reveal that precedes it
      // does not, and 0 means "not stated".
      nextHandAt: (j['nextHandAt'] as num?)?.toInt() ?? 0,
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

  /// Answers a sideshow. Only the player who was asked may; anyone else gets a
  /// refusal in the ack.
  void respondToSideshow(bool accept) =>
      _emit('game:sideshowRespond', {'accept': accept});

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
      if (j['ok'] != false) return;
      // "That table is on another server" — or "you are already seated on
      // another server" — is not a refusal so much as a forwarding address:
      // the `session:redirect` sent alongside it is already taking us there,
      // and the join (if any) is re-sent on arrival.
      if (j['code'] == 'other_worker' ||
          (j['code'] == 'already_seated' && j['path'] != null)) {
        return;
      }
      _errors.add('${j['message'] ?? 'That move was refused'}');
    });
  }

  /// Hangs up for good — signing out, or shutting down. A join a redirect
  /// left pending dies with the connection it was meant for.
  void disconnect() {
    _closeSocket();
    _joinAfterRedirect = null;
    _pathFailures = 0;
    _redirectsInARow = 0;
    _lastFailedPath = null;
    _lastFailedAt = null;
  }

  void _closeSocket() {
    _socket?.dispose();
    _socket = null;
  }

  void dispose() {
    disconnect();
    _token = null;
    _state.close();
    _session.close();
    _redirect.close();
    _cards.close();
    _showdown.close();
    _sideshowAsked.close();
    _sideshowReveal.close();
    _sideshowDone.close();
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
