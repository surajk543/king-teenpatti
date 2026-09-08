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
	NameRestoredTables      = "game_restored_tables_total"       // {source=live|postgres}
	NameRestoredSeats       = "game_restored_seats_total"
	NameRestoreReconciled   = "game_restore_reconciled_total"
	NameRestoreRejected     = "game_restore_rejected_total"
	NameRefundedPots        = "game_refunded_pots_total"
	NameRefundedChips       = "game_refunded_chips_total"
)

// The durable snapshot writer (LIVE_STATE_PLAN.md "The durable backstop"):
// game_states written asynchronously, one batch per flush.
const (
	NameSnapshotWrites        = "game_snapshot_writes_total" // {result=ok|error}
	NameSnapshotWriteDuration = "game_snapshot_write_duration_seconds"
	NameSnapshotRowsWritten   = "game_snapshot_rows_written_total"
	NameSnapshotLag           = "game_snapshot_lag_seconds" // gauge: age of the oldest dirty table
)

// HTTP.
const (
	NameHTTPRequestsTotal   = "game_http_requests_total"           // {method,route,status_code}
	NameHTTPRequestDuration = "game_http_request_duration_seconds" // {method,route,status_code}
)

// LatencyBuckets is Node's LATENCY_BUCKETS: 1 ms … 1 s.
var LatencyBuckets = []float64{0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1}

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
	// LedgerOps are the `op` values of the db transaction metrics.
	LedgerOps = map[string]struct{}{"bet": {}, "boot": {}, "settle": {}}
	// LiveOps are the `op` values of the live-store metrics: the live.Store
	// method names in snake_case, and nothing else (SafeLabel folds any other
	// value to "other").
	LiveOps = map[string]struct{}{
		LiveOpSaveTable: {}, LiveOpLoadTable: {}, LiveOpDeleteTable: {}, LiveOpListTables: {}, LiveOpCountTables: {},
		LiveOpAppendChat: {}, LiveOpLoadChat: {}, LiveOpDeleteChat: {},
		LiveOpSetSeated: {}, LiveOpClearSeated: {}, LiveOpSeatOf: {}, LiveOpListSeats: {},
		LiveOpSetOnline: {}, LiveOpSetOffline: {}, LiveOpOnlineCount: {},
		LiveOpPutResumeOffer: {}, LiveOpTakeResumeOffer: {}, LiveOpDeleteResumeOffer: {},
		LiveOpPublishTable: {}, LiveOpRetireTable: {}, LiveOpCandidates: {}, LiveOpListSummaries: {},
		LiveOpPing: {},
	}
	// LiveResults are the `result` values of game_live_store_operations_total.
	LiveResults = map[string]struct{}{LiveResultOK: {}, LiveResultNotFound: {}, LiveResultStale: {}, LiveResultError: {}}
	// WriteResults are the `result` values of game_snapshot_writes_total and
	// game_live_store_reconciles_total.
	WriteResults = map[string]struct{}{ResultOK: {}, ResultError: {}}
	// RestoreSources are the `source` values of game_restored_tables_total.
	RestoreSources = map[string]struct{}{RestoreSourceLive: {}, RestoreSourcePostgres: {}}
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
	OpBet    = "bet"
	OpBoot   = "boot"
	OpSettle = "settle"
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
	LiveOpPutResumeOffer    = "put_resume_offer"
	LiveOpTakeResumeOffer   = "take_resume_offer"
	LiveOpDeleteResumeOffer = "delete_resume_offer"
	LiveOpPublishTable      = "publish_table"
	LiveOpRetireTable       = "retire_table"
	LiveOpCandidates        = "candidates"
	LiveOpListSummaries     = "list_summaries"
	LiveOpPing              = "ping"
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

// Plain ok/error result labels (snapshot writes, reconciles).
const (
	ResultOK    = "ok"
	ResultError = "error"
)

// Restore source labels: where a rebuilt table's snapshot came from.
const (
	RestoreSourceLive     = "live"
	RestoreSourcePostgres = "postgres"
)

// HTTP route labels for requests that matched no API route.
const (
	RouteStatic    = "static"    // "/" or a path with a 2–5 char extension
	RouteUnmatched = "unmatched" // anything else
	MethodOther    = "OTHER"
)

// OtherLabel is SafeLabel's fallback.
const OtherLabel = "other"
