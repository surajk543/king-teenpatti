# The architecture documents' diagrams, as data. One spec, two outputs (SVG, Mermaid).
from diag import Flow, Seq


def system():
    f = Flow('system', 'The pieces of King Teen Patti and how they connect', 1044, 640, 'LR')
    f.group('players', 16, 34, 204, 206, 'Players', 'client')
    f.group('automation', 16, 262, 204, 122, 'Automation', 'client')
    f.group('edge', 248, 34, 140, 206, 'Edge', 'edge')
    f.group('server', 416, 34, 424, 446, 'Go server: one process, one static binary', 'core')
    f.group('state', 416, 506, 424, 118, 'State', 'data')
    f.group('outside', 868, 34, 160, 250, 'Outside services', 'ext')
    f.group('ops', 868, 306, 160, 122, 'Operations', 'ops')

    f.node('app', 30, 66, 'Flutter app', ['Android · iOS', 'the live client'], 'client', 176)
    f.node('web', 30, 152, 'Browser client', ['dev smoke test'], 'client', 176)
    f.node('auto', 30, 294, 'Bots and tools', ['bot-play fleet (Go)', 'tools/: ramp · parity'], 'client', 176)
    f.node('nginx', 260, 73, 'nginx', ['TLS · ws proxy'], 'edge', 116)

    f.node('rest', 432, 73, 'internal/auth', ['REST /api/* · JWT'], 'edge', 184)
    f.node('sio', 432, 150, 'internal/sio', ['Socket.IO, websocket only'], 'edge', 184)
    f.node('socket', 432, 227, 'internal/socket', ['guard · event handlers'], 'edge', 184)
    f.node('rooms', 432, 304, 'game.RoomManager', ['join · switch · sweep'], 'core', 184)
    f.node('tables', 432, 381, 'Table actors', ['Teen Patti · Poker', 'one goroutine each'], 'core', 184)
    f.node('metrics', 640, 150, 'internal/metrics', ['/metrics · /health'], 'ops', 184)
    f.node('stats', 640, 227, 'internal/stats', ['recorder · flusher'], 'data', 184)
    f.node('db', 640, 381, 'internal/db', ['ledger · users', 'catalogues · stats'], 'data', 184)

    f.node('redis', 432, 536, 'Redis live store', ['tables · seats · presence'], 'data', 184)
    f.node('pg', 640, 536, 'PostgreSQL', ['wallets · ledger · config'], 'data', 184)
    f.node('idp', 880, 73, 'Google · Apple', ['sign-in · receipts'], 'ext', 136)
    f.node('r2', 880, 160, 'Cloudflare R2', ['catalogue art'], 'ext', 136)
    f.node('mon', 880, 338, 'Prometheus', ['scrapes /metrics', 'Grafana · Loki'], 'ops', 136)

    f.edge('app', 'nginx')
    f.edge('web', 'nginx', sa='r', sb='l0.8')
    f.edge('auto', 'sio', 'loopback or public URL', sa='r', sb='l0.7', pts=[(396, 326.5), (396, 185.7)], lpos=0.27)
    f.edge('nginx', 'rest', '/api')
    f.edge('nginx', 'sio', '/socket.io/', sa='r0.82', sb='l0.3')
    f.edge('sio', 'socket')
    f.edge('socket', 'rooms')
    f.edge('rooms', 'tables')
    f.edge('rest', 'db', sa='r0.8', sb='l0.25', pts=[(628, 113.8), (628, 397.25)])
    f.edge('tables', 'db', sa='r0.7', sb='l0.7')
    f.edge('rest', 'idp', 'verify sign-ins, receipts', sa='r0.2', sb='l0.2', ldy=-3)
    f.edge('rest', 'r2', 'signs art links', sa='r0.5', sb='l', pts=[(854, 98.5), (854, 185.5)], lpos=0.3, ldy=5)
    f.edge('mon', 'metrics', sa='l', sb='r', pts=[(846, 370.5), (846, 175.5)])
    f.edge('tables', 'redis', 'snapshot after\nevery closure')
    f.edge('db', 'pg', '3 money\ncheckpoints')
    return f


def layers():
    f = Flow('layers', 'Packages of the Go server, in layers', 900, 566, 'TB')
    f.group('entry', 16, 24, 868, 76, 'Entry', 'plain')
    f.group('compose', 16, 110, 868, 76, 'Composition', 'plain')
    f.group('edges', 16, 196, 868, 84, 'Edges: the outside world', 'edge')
    f.group('domain', 16, 290, 868, 84, 'Domain: the rules', 'core')
    f.group('adapters', 16, 384, 868, 84, 'Adapters', 'data')
    f.group('base', 16, 478, 868, 76, 'Shared by all', 'plain')

    f.node('cmd', 360, 42, 'cmd/gameplay', ['flags · signals'], 'ops', 180)
    f.node('app', 330, 128, 'internal/app', ['wires everything · HTTP mux'], 'ops', 240)
    f.node('sio', 40, 222, 'internal/sio', ['Engine.IO + Socket.IO'], 'edge', 190)
    f.node('socket', 250, 222, 'internal/socket', ['game protocol on sio'], 'edge', 190)
    f.node('small', 460, 222, 'small services', ['appversion · assets · purchase'], 'edge', 210)
    f.node('auth', 680, 222, 'internal/auth', ['REST · JWT · providers'], 'edge', 190)
    f.node('game', 150, 316, 'internal/game', ['Table · RoomManager · Actor'], 'core', 260)
    f.node('poker', 520, 316, 'internal/poker', ['4 variants, implements Room'], 'core', 240)
    f.node('live', 40, 410, 'internal/live', ['Store: Redis or memory'], 'data', 190)
    f.node('stats', 250, 410, 'internal/stats', ['recorder · flusher'], 'data', 190)
    f.node('metrics', 460, 410, 'internal/metrics', ['game_* series'], 'data', 190)
    f.node('db', 680, 410, 'internal/db', ['Ledger · stores (pgx)'], 'data', 190)
    f.node('config', 250, 496, 'internal/config', ['env → one Config'], 'plain', 190)
    f.node('util', 460, 496, 'internal/util', ['uuid · codes · logger'], 'plain', 190)

    f.edge('cmd', 'app')
    f.edge('app', 'socket', sa='b0.3', sb='t')
    f.edge('app', 'auth', sa='b0.9', sb='t')
    f.edge('socket', 'sio')
    f.edge('socket', 'game', sa='b', sb='t0.5')
    f.edge('poker', 'game', 'implements Room')
    f.edge('game', 'live', dashed=True, sa='b0.1', sb='t', pts=[(176, 379), (135, 379)])
    f.edge('game', 'stats', dashed=True, sa='b0.6', sb='t', pts=[(306, 379), (345, 379)])
    f.edge('game', 'db', dashed=True, sa='b0.9', sb='t0.5', pts=[(384, 379), (775, 379)])
    f.edge('auth', 'db', sa='b0.74', sb='t0.74')
    return f


def hand():
    f = Flow('hand', 'The life of one hand at a Teen Patti table', 1060, 412, 'LR')
    f.node('variation', 430, 28, 'variation window', ['variation tables · chooser has 10 s'], 'ext', 240)
    f.node('waiting', 16, 170, 'WAITING', ['fewer than 2 funded seats'], 'plain', 180)
    f.node('starting', 300, 170, 'STARTING', ['next-hand delay (4 s)'], 'core', 160)
    f.node('betting', 520, 163, 'BETTING', ['turn clock 25 s', 'see · chaal · raise · pack'], 'core', 190)
    f.node('showdown', 850, 170, 'SHOWDOWN', ['hands compared, pot paid'], 'core', 170)
    f.node('sideshow', 420, 300, 'sideshow pending', ['turn frozen up to 6 s'], 'ext', 160)
    f.node('pick', 620, 300, '5-card pick', ['choose 3 of 5 within 8 s'], 'ext', 170)
    f.node('settle', 850, 300, 'endHand → Settle', ['checkpoint 3 · stats · XP'], 'data', 180)

    f.edge('waiting', 'starting', '2+ funded seats', ldy=-14)
    f.edge('starting', 'betting', 'deal')
    f.edge('starting', 'variation', 'variation table', sa='t', sb='l', lpos=0.4)
    f.edge('variation', 'betting', 'chosen, or\ntimeout → Muflis', sa='b0.6917', sb='t0.4')
    f.edge('betting', 'showdown', 'show · missile · cap')
    f.edge('betting', 'sideshow', 'ask ↔ answer', sa='b0.2', sb='t', both=True)
    f.edge('betting', 'pick', 'look at 5 cards', sa='b0.75', sb='t', both=True)
    f.edge('showdown', 'settle', sa='b', sb='t0.472')
    f.edge('betting', 'settle', 'one player left', sa='r0.85', sb='l', pts=[(820, 218.25), (820, 325.5)], lpos=0.6)
    f.edge('settle', 'waiting', 'pot paid, seats swept, next hand', sa='b', sb='b', pts=[(940, 392), (106, 392)])
    return f


def stats():
    f = Flow('stats', 'How a hand reaches player_stats: Redis first, then one group commit', 852, 252, 'LR')
    f.node('table', 16, 40, 'Table actor', ['hand end or leave', 'works out HandStats'], 'core', 160)
    f.node('commit', 236, 40, 'ledger commit', ['Settle / Checkpoint', 'money only'], 'data', 160)
    f.node('rec', 456, 40, 'stats.Recorder', ['a queue,', 'off the actor'], 'data', 160)
    f.node('redis', 676, 40, 'Redis', ['kt:stats:<userId>', 'HINCRBY per field'], 'data', 160)
    f.node('flush', 676, 170, 'stats.Flusher', ['every STATS_FLUSH_MS', 'up to 500 players'], 'data', 160)
    f.node('pg', 456, 170, 'PostgreSQL', ['stats_flushes receipt', 'player_stats upsert'], 'data', 160)
    f.node('read', 236, 177, 'account read', ["sums a player's rows"], 'edge', 160)

    f.edge('table', 'commit', '1')
    f.edge('commit', 'rec', '2')
    f.edge('rec', 'redis', '3')
    f.edge('redis', 'flush', '4', sa='b0.3', sb='t0.3')
    f.edge('flush', 'pg', '5')
    f.edge('flush', 'redis', '6', sa='t0.7', sb='b0.7', dashed=True)
    f.edge('pg', 'read', '7')
    return f


def boot():
    f = Flow('boot', 'What the process does between exec and the first request', 900, 232, 'LR')
    f.node('cfg', 16, 30, 'config.Load', ['env → one Config', 'malformed value stops'], 'plain', 190)
    f.node('dbo', 242, 30, 'db.Open', ['pool · search_path', 'every migration, every boot'], 'data', 190)
    f.node('live', 468, 30, 'live.Open', ['Redis or memory', 'unreachable → fail fast'], 'data', 190)
    f.node('cat', 694, 30, 'table catalogue', ['TABLE_CONFIG_SOURCE', 'db rows or env keys'], 'core', 190)
    f.node('wire', 694, 150, 'stores, sio, handler', ['RoomManager ↔ socket', 'XP tracker · stats recorder'], 'edge', 190)
    f.node('restore', 468, 150, 'restore rooms', ['Redis snapshots → actors', 'seats held for the grace'], 'core', 190)
    f.node('jobs', 242, 150, 'background jobs', ['sweeper · reconciler', 'stats flusher · purge'], 'ops', 190)
    f.node('listen', 16, 150, 'listen', ['routes · /health', 'HOST:PORT'], 'edge', 190)
    for a, b in [('cfg', 'dbo'), ('dbo', 'live'), ('live', 'cat'), ('cat', 'wire'), ('wire', 'restore'), ('restore', 'jobs'), ('jobs', 'listen')]:
        f.edge(a, b)
    return f


def event():
    s = Seq('event', 'One move, from the tap to every screen', [
        ('app', 'Flutter app', 'client'), ('sio', 'internal/sio', 'edge'), ('h', 'socket.Handler', 'edge'),
        ('t', 'Table actor', 'core'), ('r', 'Redis', 'data')], col=190)
    s.msg('app', 'sio', 'game:action {chaal, amount, actionId}')
    s.msg('sio', 'h', 'guard(game:action)')
    s.self_('h', 'rate limits: 30 per 5 s per socket and per account')
    s.msg('h', 't', 'Table.Act(user, chaal, {amount, actionId})')
    s.note('t', 't', 'ONE closure on the actor goroutine:\nin a hand? your turn? sideshow pending?\namount on the ladder? actionId unused? chips?')
    s.self_('t', 'chargeToPot: seat −, pot +\n(memory only)')
    s.self_('t', 'advanceTurn → setTurn(next)\n→ turn clock armed')
    s.msg('t', 'h', 'Listener: OnAction · OnTurn · OnState')
    s.msg('h', 'app', 'game:action to the room · room:state, one redacted copy per viewer')
    s.reply('t', 'h', 'ActResult')
    s.reply('h', 'app', 'ack {ok: true, action, amount}')
    s.msg('t', 'r', 'after(): SaveTable(roomId, seq + 1, snapshot)')
    s.note('h', 'r', 'No PostgreSQL write: a bet never leaves the process')
    return s


def join():
    s = Seq('join', 'Quick join: from the lobby card to a seat', [
        ('app', 'Flutter app', 'client'), ('h', 'socket.Handler', 'edge'), ('pg', 'PostgreSQL', 'data'),
        ('rm', 'RoomManager', 'core'), ('t', 'Table actor', 'core'), ('r', 'Redis', 'data')], col=170)
    s.msg('app', 'h', 'room:quickJoin {bootAmount, category}')
    s.msg('h', 'pg', 'Users.FindByID: the account as it is NOW')
    s.msg('h', 'rm', 'QuickJoin(player, {boot, category})')
    s.note('rm', 'rm', "lock the player's seat stripe, then in order:\nalready seated? · stake allowed? · table offered?\nLoadPlayer (wallet read under the lock) · chips ≥ boot\nentry cap · stack band")
    s.self_('rm', 'under mu: FULLEST open table of\nthis boot + category, else a new\none; hold a seat on it')
    s.msg('rm', 't', 'AddPlayer(seat = wallet)')
    s.msg('t', 'r', 'seat mirror · playing record · snapshot')
    s.reply('rm', 'h', 'the room')
    s.msg('h', 't', 'trackRoom · SetConnected(true, socketId)')
    s.msg('t', 'h', 'OnState')
    s.msg('h', 'app', 'room:state to every viewer · room:joined · chat:history')
    s.reply('h', 'app', 'ack {roomId, code, category}')
    s.note('t', 't', '2 funded seats → STARTING\n→ the deal after the delay')
    return s


def switch():
    s = Seq('switch', 'Switch table: a sideways move at the same stake', [
        ('app', 'Flutter app', 'client'), ('h', 'socket.Handler', 'edge'), ('rm', 'RoomManager', 'core'),
        ('a', 'Table A (old)', 'core'), ('b', 'Table B (new)', 'core'), ('pg', 'PostgreSQL', 'data')], col=170)
    s.msg('app', 'h', 'room:switch {}')
    s.self_('h', 'stop listening to A first (untrackRoom)')
    s.msg('h', 'rm', 'SwitchTable(player)')
    s.note('rm', 'rm', "seat stripe · seated? · A is public?\ntarget = another table, same boot + category,\nwith the FEWEST players (random among ties);\nnone free → open a new table for the player")
    s.self_('rm', 'hold a seat at B, then\nassertAdmitsMove(B, seat chips)')
    s.msg('rm', 'a', 'RemovePlayer(user, "moved")')
    s.msg('a', 'pg', 'mid-hand: Checkpoint hand_left')
    s.reply('a', 'rm', 'the vacated seat, chips as held')
    s.self_('rm', 'A is now empty → destroy A')
    s.msg('rm', 'b', 'AddPlayer(chips carried from the seat)')
    s.reply('rm', 'h', 'SwitchResult{From: A, To: B}')
    s.msg('h', 'app', 'room:joined (B) · chat:history · room:state to A and B')
    s.reply('h', 'app', 'ack {roomId, code, category}')
    s.note('rm', 'b', 'B refuses the seat → the seat at A is restored')
    return s


def money():
    s = Seq('money', 'When chips reach PostgreSQL: the three checkpoints', [
        ('t', 'Table actor', 'core'), ('r', 'Redis', 'data'), ('l', 'db.Ledger', 'data'),
        ('pg', 'PostgreSQL', 'data'), ('s', 'stats.Recorder', 'data')], col=190)
    s.band('deal · chaal · raise · show · see')
    s.self_('t', 'chips move in memory')
    s.msg('t', 'r', 'snapshot (seq + 1)')
    s.note('l', 'pg', 'nothing is written to PostgreSQL')
    s.band('checkpoint 1: a player packs')
    s.msg('t', 'l', 'Checkpoint{hand_packed, <hand>:packed:<user>, delta}')
    s.msg('l', 'pg', 'BEGIN · SELECT chips FOR UPDATE · UPDATE · INSERT chip_ledger · COMMIT')
    s.band('checkpoint 2: a player leaves, switches or is kicked')
    s.msg('t', 'l', 'Checkpoint{hand_left, <hand>:left:<user>, delta}')
    s.band('checkpoint 3: the hand ends')
    s.msg('t', 'l', 'Settle{one entry for everyone still at the table}')
    s.msg('l', 'pg', 'ONE transaction, wallets locked in id order:\nhand_win / hand_loss rows · table_tax row · XP')
    s.reply('l', 't', 'balances · tax rates · levels')
    s.msg('t', 's', 'the hand\'s counters, only after the commit')
    s.note('t', 'l', 'answer lost? the Settler resends the same request up to 10 times;\nthe UNIQUE action_id turns a replay into duplicate_action = success')
    return s


def resume():
    s = Seq('resume', 'A dropped connection: the grace, then the offer', [
        ('app', 'Flutter app', 'client'), ('h', 'socket.Handler', 'edge'), ('t', 'Table actor', 'core'),
        ('rm', 'RoomManager', 'core'), ('r', 'Redis', 'data')], col=190)
    s.band('the socket drops, or the app has been in the background for 8 s')
    s.msg('h', 't', 'SetConnected(user, false)')
    s.self_('h', 'holdSeat: RECONNECT_GRACE_MS (60 s)')
    s.note('t', 't', 'turn clocks keep running:\na missed turn packs the player')
    s.band('back within the grace')
    s.msg('app', 'h', 'handshake: JWT (sv) · app platform and version')
    s.msg('h', 'app', 'session:ready · room:joined · chat:history')
    s.band('the grace ran out')
    s.msg('h', 'rm', 'Leave(user, "disconnected")')
    s.msg('h', 'r', 'PutResumeOffer(user, room, RESUME_OFFER_MS = 10 min)')
    s.msg('app', 'h', 'handshake')
    s.msg('h', 'app', 'session:ready {resume: {roomId, code, category, bootAmount}}')
    s.msg('app', 'h', 'room:joinCode {code}')
    return s


ALL = {d.name: d for d in [system(), layers(), hand(), stats(), boot(), event(), join(), switch(), money(), resume()]}
