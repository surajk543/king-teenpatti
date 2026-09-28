// Package metrics is the port of server/src/metrics/index.js (requirement 35):
// one Prometheus registry exposed on /metrics.
//
// Two families:
//   - process/runtime metrics under config.Metrics.Prefix ("game_server_"):
//     collectors.NewProcessCollector(ProcessCollectorOpts{Namespace:
//     "game_server"}) gives game_server_process_cpu_seconds_total,
//     _resident_memory_bytes, _open_fds, _start_time_seconds …;
//     prometheus.WrapRegistererWithPrefix("game_server_", reg) wrapping
//     collectors.NewGoCollector() gives game_server_go_* (goroutines, GC, heap).
//     Node's game_server_nodejs_* series have no Go equivalent and are NOT
//     emulated (PORT_PLAN.md §Metrics lists the dashboard panels affected);
//     game_server_process_uptime_seconds is kept as a custom gauge.
//   - game metrics under "game_": names, help strings, label names and
//     histogram buckets IDENTICAL to Node — the Grafana dashboard in
//     server/ops/monitoring must work unchanged.
//
// Label discipline (enforced by SafeLabel and, in Node, test/metrics.test.js):
// every label has a small fixed value set (event name, action, route
// pattern, status code, reason code). No label EVER carries a socket id, user
// id, room id, table code, display name, raw URL or IP address. SafeLabel is
// the last line of defence: a value outside the known set becomes "other".
package metrics

// DefaultServiceLabel is the registry-wide default label {service="king-teenpatti"}.
const (
	ServiceLabelName  = "service"
	ServiceLabelValue = "king-teenpatti"
)

// Custom process gauge kept from Node.
const NameProcessUptimeSeconds = "process_uptime_seconds" // prefixed → game_server_process_uptime_seconds

// Socket metrics.
const (
	NameConnectedSockets     = "game_connected_sockets"      // gauge
	NameConnectedSocketsPeak = "game_connected_sockets_peak" // gauge
	NameConnectionsTotal     = "game_connections_total"      // counter
	NameDisconnectionsTotal  = "game_disconnections_total"   // counter{reason}
	NameReconnectsTotal      = "game_reconnects_total"       // counter{kind=seat_held|offer}
	NameSocketErrorsTotal    = "game_socket_errors_total"    // counter{code}
	NameSocketMessagesTotal  = "game_socket_messages_total"  // counter{event}
	NameSocketEmitsTotal     = "game_socket_emits_total"     // counter{event}
	NameSessionReplacedTotal = "game_session_replaced_total" // counter
)

// Table gauges (collected at scrape time from the RoomManager).
const (
	NamePlayersOnline = "game_players_online" // gauge: sum of PlayerCount
	NameActiveGames   = "game_active_games"   // gauge: tables with HasHand
	NameWaitingGames  = "game_waiting_games"  // gauge: tables without a hand
	NameTables        = "game_tables"         // gauge{category,stake}
)

// Game counters.
const (
	NameGamesStartedTotal   = "game_games_started_total"   // {category}
	NameGamesCompletedTotal = "game_games_completed_total" // {category,reason}
	NameGamesAbandonedTotal = "game_games_abandoned_total" // {category}
	NameMovesTotal          = "game_moves_total"           // {action}
	NameInvalidMovesTotal   = "game_invalid_moves_total"   // {code}
	NameTurnTimeoutsTotal   = "game_turn_timeouts_total"
	NameKicksTotal          = "game_kicks_total" // {reason}
	NameChatMessagesTotal   = "game_chat_messages_total"
	NamePotSettledTotal     = "game_pot_settled_chips_total"
	// NameTableTaxTotal is the winning tax taken from hand winners at the
	// tables that tax them (owner, 26 Sep 2026) — chips that left the game.
	NameTableTaxTotal = "game_table_tax_chips_total" // {category}
)

// Latency histograms (buckets LatencyBuckets).
const (
	NameMoveDuration          = "game_move_processing_duration_seconds" // {action}
	NameCreationDuration      = "game_creation_duration_seconds"
	NameJoinDuration          = "game_join_duration_seconds" // {route}
	NameStateUpdateDuration   = "game_state_update_duration_seconds"
	NameHandStartDuration     = "game_hand_start_duration_seconds"
	NameSettlementDuration    = "game_settlement_duration_seconds"
	NameDBTransactionDuration = "game_db_transaction_duration_seconds" // {op}
	NameDBTransactionErrors   = "game_db_transaction_errors_total"     // {op,code}
)

// Pool gauges.
const (
	NameDBPoolConnections     = "game_db_pool_connections"
	NameDBPoolIdleConnections = "game_db_pool_idle_connections"
	NameDBPoolWaitingRequests = "game_db_pool_waiting_requests"
)

// Live-state store (LIVE_STATE_PLAN.md §Metrics): every Store call by
// method and outcome, its latency, real failures, and what a restart
// rebuilt or refunded.
const (
	NameLiveStoreOperations = "game_live_store_operations_total" // {op,result}
	NameLiveStoreDuration   = "game_live_store_duration_seconds" // {op}
	NameLiveStoreErrors     = "game_live_store_errors_total"     // {op}
	NameLiveStoreReconciles = "game_live_store_reconciles_total" // {result}
	NameRestoredTables      = "game_restored_tables_total"       // no labels: the live store is the only source
	NameRestoredSeats       = "game_restored_seats_total"
)

// Player statistics (Player stats v2, owner 27 Sep 2026): the stats
// flusher's group commits from the live store into PostgreSQL. No label ever
// names a player: result is one of StatsFlushResults, and the players of a
// batch are a histogram's observation, not a label.
const (
	NameStatsFlushes      = "game_stats_flushes_total" // {result}
	NameStatsFlushPlayers = "game_stats_flush_players" // histogram, players per committed batch
)

// The app version gate (owner, 28 Sep 2026; appversion). No label ever carries
// the version a client sent: platform is one of AppPlatforms, status one of
// AppStatuses and via one of AppVias — the version is in the log line, never
// in a series.
const (
	NameAppVersionChecks     = "game_app_version_checks_total"     // {platform,status}: GET /api/app-config verdicts
	NameAppVersionRejections = "game_app_version_rejections_total" // {platform,status,via}: refused REST calls and handshakes
)

// HTTP.
const (
	NameHTTPRequestsTotal   = "game_http_requests_total"           // {method,route,status_code}
	NameHTTPRequestDuration = "game_http_request_duration_seconds" // {method,route,status_code}
)

// LatencyBuckets is Node's LATENCY_BUCKETS: 1 ms … 1 s.
var LatencyBuckets = []float64{0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1}

// StatsFlushPlayersBuckets are game_stats_flush_players' buckets: how many
// players one committed batch held, up to STATS_FLUSH_BATCH's default and a
// little past it.
var StatsFlushPlayersBuckets = []float64{1, 5, 10, 25, 50, 100, 250, 500, 1000}

// LiveBuckets are game_live_store_duration_seconds' buckets: 0.1 ms … 1 s —
// finer at the bottom than LatencyBuckets because a Redis round trip on the
// same host is a fraction of a millisecond and the in-process store is
// microseconds.
var LiveBuckets = []float64{0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1}

// Fixed label value sets.
var (
	// JoinRoutes are the `route` values of game_join_duration_seconds.
	JoinRoutes = map[string]struct{}{"quick_join": {}, "code": {}, "create": {}, "switch": {}, "resume": {}}
	// ReconnectKinds are the `kind` values of game_reconnects_total.
	ReconnectKinds = map[string]struct{}{"seat_held": {}, "offer": {}}
	// LedgerOps are the `op` values of the db transaction metrics. Since
	// 9 Sep 2026 a hand costs two kinds of chip transaction and no more: a
	// per-player `checkpoint` (a pack, a leave or a switch) and the hand-end
	// `settle`. `bet` and `boot` are retired — a bet and the deal write
	// nothing. `hammer_spend` (13 Sep 2026) is the third op and not a chip
	// write: the hammer a Force Sideshow takes. `missile_spend` (14 Sep 2026)
	// is its twin: the missile a missile showdown takes.
	LedgerOps = map[string]struct{}{OpCheckpoint: {}, OpSettle: {}, OpHammerSpend: {}, OpMissileSpend: {}}
	// LiveOps are the `op` values of the live-store metrics: the live.Store
	// method names in snake_case, and nothing else (SafeLabel folds any other
	// value to "other").
	LiveOps = map[string]struct{}{
		LiveOpSaveTable: {}, LiveOpLoadTable: {}, LiveOpDeleteTable: {}, LiveOpListTables: {}, LiveOpCountTables: {},
		LiveOpAppendChat: {}, LiveOpLoadChat: {}, LiveOpDeleteChat: {},
		LiveOpSetSeated: {}, LiveOpClearSeated: {}, LiveOpSeatOf: {}, LiveOpListSeats: {},
		LiveOpSetOnline: {}, LiveOpSetOffline: {}, LiveOpOnlineCount: {}, LiveOpPresence: {},
		LiveOpPutResumeOffer: {}, LiveOpTakeResumeOffer: {}, LiveOpDeleteResumeOffer: {},
		LiveOpPublishTable: {}, LiveOpRetireTable: {}, LiveOpCandidates: {}, LiveOpListSummaries: {},
		LiveOpRecordStats: {}, LiveOpTakeStatsBatch: {}, LiveOpStatsBatches: {}, LiveOpFinishStatsBatch: {}, LiveOpDropStats: {},
		LiveOpPing: {},
	}
	// StatsFlushResults are the `result` values of game_stats_flushes_total:
	// a batch committed (ok), found committed already — its acknowledgement
	// lost — and so added again nowhere (duplicate), or refused (error, to be
	// retried under the same id).
	StatsFlushResults = map[string]struct{}{StatsFlushOK: {}, StatsFlushDuplicate: {}, StatsFlushError: {}}
	// LiveResults are the `result` values of game_live_store_operations_total.
	LiveResults = map[string]struct{}{LiveResultOK: {}, LiveResultNotFound: {}, LiveResultStale: {}, LiveResultError: {}}
	// WriteResults are the `result` values of game_live_store_reconciles_total.
	WriteResults = map[string]struct{}{ResultOK: {}, ResultError: {}}
	// AppPlatforms are the `platform` values of the app version gate's two
	// counters: what appversion.Client.Label answers — the platforms a client
	// may declare, "none" for none and "other" for one the server does not
	// know.
	AppPlatforms = map[string]struct{}{"android": {}, "ios": {}, "bot": {}, "tool": {}, "web": {}, "none": {}, OtherLabel: {}}
	// AppStatuses are their `status` values: the four states, lower-cased.
	AppStatuses = map[string]struct{}{"normal": {}, "soft_update": {}, "force_update": {}, "maintenance": {}}
	// AppVias are game_app_version_rejections_total's `via` values.
	AppVias = map[string]struct{}{"rest": {}, "socket": {}}
	// HTTPMethods are the accepted `method` labels; anything else is "OTHER".
	HTTPMethods = map[string]struct{}{"GET": {}, "POST": {}, "PUT": {}, "PATCH": {}, "DELETE": {}, "HEAD": {}, "OPTIONS": {}}
)

// Join route label values.
const (
	RouteQuickJoin = "quick_join"
	RouteCode      = "code"
	RouteCreate    = "create"
	RouteSwitch    = "switch"
	RouteResume    = "resume"
)

// Reconnect kinds.
const (
	ReconnectSeatHeld = "seat_held"
	ReconnectOffer    = "offer"
)

// Ledger op labels.
const (
	// OpCheckpoint is one player's pack / leave-or-switch write.
	OpCheckpoint = "checkpoint"
	// OpSettle is the hand-end write: everyone still at the table, plus the
	// hands row.
	OpSettle = "settle"
	// OpHammerSpend is the one hammer a Force Sideshow takes (db.Hammers). Not
	// a chip write — it touches users.hammer and hammer_spends only — but a
	// transaction the table blocks on all the same, so it is timed with them.
	OpHammerSpend = "hammer_spend"
	// OpMissileSpend is the one missile a missile takes (db.Missiles): users.
	// missile and missile_spends only, timed because the table blocks on it.
	OpMissileSpend = "missile_spend"
)

// Live-store op labels: one per live.Store method.
const (
	LiveOpSaveTable         = "save_table"
	LiveOpLoadTable         = "load_table"
	LiveOpDeleteTable       = "delete_table"
	LiveOpListTables        = "list_tables"
	LiveOpCountTables       = "count_tables"
	LiveOpAppendChat        = "append_chat"
	LiveOpLoadChat          = "load_chat"
	LiveOpDeleteChat        = "delete_chat"
	LiveOpSetSeated         = "set_seated"
	LiveOpClearSeated       = "clear_seated"
	LiveOpSeatOf            = "seat_of"
	LiveOpListSeats         = "list_seats"
	LiveOpSetOnline         = "set_online"
	LiveOpSetOffline        = "set_offline"
	LiveOpOnlineCount       = "online_count"
	LiveOpPresence          = "presence" // the friends endpoints' batched read of who is online and playing (Friends V1)
	LiveOpPutResumeOffer    = "put_resume_offer"
	LiveOpTakeResumeOffer   = "take_resume_offer"
	LiveOpDeleteResumeOffer = "delete_resume_offer"
	LiveOpPublishTable      = "publish_table"
	LiveOpRetireTable       = "retire_table"
	LiveOpCandidates        = "candidates"
	LiveOpListSummaries     = "list_summaries"
	// The players' statistics (Player stats v2): recorded after every
	// committed hand, and moved out, listed, finished and dropped by the stats
	// flusher and an account deletion.
	LiveOpRecordStats      = "record_stats"
	LiveOpTakeStatsBatch   = "take_stats_batch"
	LiveOpStatsBatches     = "stats_batches"
	LiveOpFinishStatsBatch = "finish_stats_batch"
	LiveOpDropStats        = "drop_stats"
	LiveOpPing             = "ping"
)

// Stats flush result labels (StatsFlushResults).
const (
	StatsFlushOK        = "ok"
	StatsFlushDuplicate = "duplicate"
	StatsFlushError     = "error"
)

// Live-store result labels. not_found and stale are ordinary outcomes of a
// lookup / a compare-and-set, not failures: only `error` feeds
// game_live_store_errors_total.
const (
	LiveResultOK       = "ok"
	LiveResultNotFound = "not_found"
	LiveResultStale    = "stale"
	LiveResultError    = "error"
)

// Plain ok/error result labels (reconciles).
const (
	ResultOK    = "ok"
	ResultError = "error"
)

// HTTP route labels for requests that matched no API route.
const (
	RouteStatic    = "static"    // "/" or a path with a 2–5 char extension
	RouteUnmatched = "unmatched" // anything else
	MethodOther    = "OTHER"
)

// OtherLabel is SafeLabel's fallback.
const OtherLabel = "other"
