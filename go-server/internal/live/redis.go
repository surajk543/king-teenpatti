package live

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

// Redis is the production Store (REDIS_URL set). Key schema, prefix "kt:"
// (LIVE_STATE_PLAN.md):
//
//	kt:table:<roomId>            hash   seq, snapshot, handId, updatedAt   PEXPIRE ttl on every save
//	kt:tables                    set    room ids with a stored snapshot
//	kt:chat:<roomId>             list   serialised messages, RPUSH + LTRIM to max   PEXPIRE auxTTL
//	kt:seat:<userId>             string roomId                                       (no ttl)
//	kt:online                    hash   userId → "<instance>|<expiresAtMs>"
//	kt:resume:<userId>           string ResumeOffer JSON                            PX ttl
//	kt:lobby:<category>:<boot>   zset   roomId scored by players; private tables never indexed
//	kt:summary:<roomId>          hash   TableSummary fields                           PEXPIRE auxTTL
//
// SaveTable (compare-and-set) and OnlineCount (count + reap) are Lua scripts;
// TakeResumeOffer is GETDEL (Redis ≥ 6.2). Every call runs under
// Options.Timeout (default 500 ms) on top of the caller's context.
type Redis struct {
	client  *redis.Client
	prefix  string
	timeout time.Duration
	addr    string
	// now is the process clock used for updatedAt and the online-presence
	// expiry stamps; tests replace it to drive expiry together with the
	// server's clock.
	now func() time.Time
}

// saveTableScript is the CAS behind SaveTable.
//
//	KEYS[1] = kt:table:<roomId>   KEYS[2] = kt:tables
//	ARGV    = seq, snapshot, handId, updatedAt, ttlMs, roomId
//
// Returns 1 when the snapshot was written, 0 when the stored seq is already
// >= the offered one (→ ErrStale). The read and the write happen inside one
// script invocation, so two processes racing on a table cannot both win.
var saveTableScript = redis.NewScript(`
local stored = redis.call('HGET', KEYS[1], 'seq')
if stored and tonumber(stored) >= tonumber(ARGV[1]) then
  return 0
end
redis.call('HSET', KEYS[1], 'seq', ARGV[1], 'snapshot', ARGV[2], 'handId', ARGV[3], 'updatedAt', ARGV[4])
if tonumber(ARGV[5]) > 0 then
  redis.call('PEXPIRE', KEYS[1], ARGV[5])
else
  redis.call('PERSIST', KEYS[1])
end
redis.call('SADD', KEYS[2], ARGV[6])
return 1
`)

// onlineCountScript counts the presence entries whose expiry stamp is still
// in the future and reaps the rest, atomically, so a refresh landing between
// a read and a delete can never be lost.
//
//	KEYS[1] = kt:online   ARGV[1] = nowMs
var onlineCountScript = redis.NewScript(`
local entries = redis.call('HGETALL', KEYS[1])
local now = tonumber(ARGV[1])
local count = 0
for i = 1, #entries, 2 do
  local value = entries[i + 1]
  local sep = string.find(value, '|', 1, true)
  local expires = sep and tonumber(string.sub(value, sep + 1)) or nil
  if expires and expires > now then
    count = count + 1
  else
    redis.call('HDEL', KEYS[1], entries[i])
  end
end
return count
`)

// OpenRedis connects to Redis and returns the production Store. It pings
// once and fails fast with a clear error when the server is unreachable.
func OpenRedis(ctx context.Context, opts Options) (Store, error) {
	if opts.URL == "" {
		return nil, errors.New("live: OpenRedis needs a REDIS_URL")
	}
	ro, err := redis.ParseURL(opts.URL)
	if err != nil {
		return nil, fmt.Errorf("live: invalid REDIS_URL: %w", err)
	}
	timeout := opts.Timeout
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	prefix := opts.KeyPrefix
	if prefix == "" {
		prefix = DefaultKeyPrefix
	}
	// One bounded round trip per call: the per-call context carries the
	// deadline and the socket timeouts back it up.
	ro.ContextTimeoutEnabled = true
	ro.DialTimeout = timeout
	ro.ReadTimeout = timeout
	ro.WriteTimeout = timeout
	ro.MaxRetries = 1

	r := &Redis{
		client:  redis.NewClient(ro),
		prefix:  prefix,
		timeout: timeout,
		addr:    ro.Addr,
		now:     time.Now,
	}
	if err := r.Ping(ctx); err != nil {
		_ = r.client.Close()
		return nil, fmt.Errorf("live: redis at %s (db %d) unreachable: %w", ro.Addr, ro.DB, err)
	}
	return r, nil
}

// Kind implements Store.
func (r *Redis) Kind() string { return "redis" }

// Ping implements Store.
func (r *Redis) Ping(ctx context.Context) error {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	return r.client.Ping(ctx).Err()
}

// Close implements Store.
func (r *Redis) Close() error { return r.client.Close() }

// bound derives the per-call context (the caller's earlier deadline wins).
func (r *Redis) bound(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(ctx, r.timeout)
}

// ---- keys -----------------------------------------------------------------

func (r *Redis) keyTable(roomID string) string   { return r.prefix + "table:" + roomID }
func (r *Redis) keyTables() string               { return r.prefix + "tables" }
func (r *Redis) keyChat(roomID string) string    { return r.prefix + "chat:" + roomID }
func (r *Redis) keySeat(userID string) string    { return r.prefix + "seat:" + userID }
func (r *Redis) keyOnline() string               { return r.prefix + "online" }
func (r *Redis) keyResume(userID string) string  { return r.prefix + "resume:" + userID }
func (r *Redis) keySummary(roomID string) string { return r.prefix + "summary:" + roomID }
func (r *Redis) keyLobby(category string, bootAmount int64) string {
	return r.prefix + "lobby:" + lobbyBucket(category, bootAmount)
}

// ---- live table state ----------------------------------------------------

// SaveTable implements Store (one Lua round trip, see saveTableScript).
func (r *Redis) SaveTable(ctx context.Context, roomID string, seq int64, snapshot []byte, ttl time.Duration) error {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	n, err := saveTableScript.Run(ctx, r.client,
		[]string{r.keyTable(roomID), r.keyTables()},
		seq, snapshot, HandIDOf(snapshot), r.now().UnixMilli(), ttl.Milliseconds(), roomID,
	).Int64()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrStale
	}
	return nil
}

// LoadTable implements Store (HMGET seq snapshot).
func (r *Redis) LoadTable(ctx context.Context, roomID string) (int64, []byte, error) {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	vals, err := r.client.HMGet(ctx, r.keyTable(roomID), "seq", "snapshot").Result()
	if err != nil {
		return 0, nil, err
	}
	seqStr, ok := vals[0].(string)
	if !ok {
		return 0, nil, ErrNotFound
	}
	seq, err := strconv.ParseInt(seqStr, 10, 64)
	if err != nil {
		return 0, nil, fmt.Errorf("live: corrupt seq %q for table %s: %w", seqStr, roomID, err)
	}
	snap, _ := vals[1].(string)
	return seq, []byte(snap), nil
}

// DeleteTable implements Store (DEL hash + SREM set).
func (r *Redis) DeleteTable(ctx context.Context, roomID string) error {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	_, err := r.client.TxPipelined(ctx, func(p redis.Pipeliner) error {
		p.Del(ctx, r.keyTable(roomID))
		p.SRem(ctx, r.keyTables(), roomID)
		return nil
	})
	return err
}

// ListTables implements Store: SMEMBERS, then one pipelined HGET seq per
// member; members whose hash has expired are dropped from the set. Sorted
// by room id.
// CountTables is one SCARD on the index set — O(1), whatever the table count.
// This is what /health calls; ListTables would be one round trip per table
// (1,130 commands per health check at 7,000 players, measured on production
// 9 Sep 2026, which pushed /health p95 to 1.1 s and eventually timed it out).
// The set can briefly hold a room whose hash has expired, so the number may
// run a little high until ListTables sweeps it; that runs at startup and in
// the reconciler.
func (r *Redis) CountTables(ctx context.Context) (int, error) {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	n, err := r.client.SCard(ctx, r.keyTables()).Result()
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

func (r *Redis) ListTables(ctx context.Context) ([]TableRef, error) {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	ids, err := r.client.SMembers(ctx, r.keyTables()).Result()
	if err != nil {
		return nil, err
	}
	if len(ids) == 0 {
		return []TableRef{}, nil
	}
	cmds := make([]*redis.StringCmd, len(ids))
	_, err = r.client.Pipelined(ctx, func(p redis.Pipeliner) error {
		for i, id := range ids {
			cmds[i] = p.HGet(ctx, r.keyTable(id), "seq")
		}
		return nil
	})
	if err != nil && !errors.Is(err, redis.Nil) {
		return nil, err
	}
	refs := make([]TableRef, 0, len(ids))
	var gone []interface{}
	for i, id := range ids {
		seqStr, err := cmds[i].Result()
		if errors.Is(err, redis.Nil) {
			gone = append(gone, id)
			continue
		}
		if err != nil {
			return nil, err
		}
		seq, err := strconv.ParseInt(seqStr, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("live: corrupt seq %q for table %s: %w", seqStr, id, err)
		}
		refs = append(refs, TableRef{RoomID: id, Seq: seq})
	}
	if len(gone) > 0 {
		// Best effort: the set is only an index over hashes that expire on
		// their own; a failure here just means the next ListTables re-tries.
		_ = r.client.SRem(ctx, r.keyTables(), gone...).Err()
	}
	sort.Slice(refs, func(i, j int) bool { return refs[i].RoomID < refs[j].RoomID })
	return refs, nil
}

// ---- chat -----------------------------------------------------------------

// AppendChat implements Store: RPUSH + LTRIM -max..-1 (+ PEXPIRE auxTTL) in
// one MULTI. max <= 0 leaves the list uncapped.
func (r *Redis) AppendChat(ctx context.Context, roomID string, message []byte, max int) error {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	key := r.keyChat(roomID)
	_, err := r.client.TxPipelined(ctx, func(p redis.Pipeliner) error {
		p.RPush(ctx, key, message)
		if max > 0 {
			p.LTrim(ctx, key, int64(-max), -1)
		}
		p.PExpire(ctx, key, auxTTL)
		return nil
	})
	return err
}

// LoadChat implements Store (LRANGE 0 -1); oldest first, never nil.
func (r *Redis) LoadChat(ctx context.Context, roomID string) ([][]byte, error) {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	vals, err := r.client.LRange(ctx, r.keyChat(roomID), 0, -1).Result()
	if err != nil {
		return nil, err
	}
	out := make([][]byte, len(vals))
	for i, v := range vals {
		out[i] = []byte(v)
	}
	return out, nil
}

// DeleteChat implements Store.
func (r *Redis) DeleteChat(ctx context.Context, roomID string) error {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	return r.client.Del(ctx, r.keyChat(roomID)).Err()
}

// ---- presence -------------------------------------------------------------

// SetSeated implements Store (SET, no ttl — RoomManager clears it).
func (r *Redis) SetSeated(ctx context.Context, userID, roomID string) error {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	return r.client.Set(ctx, r.keySeat(userID), roomID, 0).Err()
}

// ClearSeated implements Store.
func (r *Redis) ClearSeated(ctx context.Context, userID string) error {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	return r.client.Del(ctx, r.keySeat(userID)).Err()
}

// scanSuffixes walks every key matching prefix+pattern with SCAN — never
// KEYS, which blocks the whole server — and returns what follows the prefix
// (the user id, the room id). Each round trip is bounded on its own so a
// large keyspace cannot hang on a single deadline; the caller's ctx bounds
// the walk as a whole.
func (r *Redis) scanSuffixes(ctx context.Context, infix string) ([]string, error) {
	match := r.prefix + infix + "*"
	trim := len(r.prefix + infix)
	seen := make(map[string]struct{})
	out := []string{}
	var cursor uint64
	for {
		cctx, cancel := r.bound(ctx)
		keys, next, err := r.client.Scan(cctx, cursor, match, scanBatch).Result()
		cancel()
		if err != nil {
			return nil, err
		}
		for _, key := range keys {
			// SCAN may return a key more than once across cursors.
			if len(key) <= trim {
				continue
			}
			id := key[trim:]
			if _, dup := seen[id]; dup {
				continue
			}
			seen[id] = struct{}{}
			out = append(out, id)
		}
		cursor = next
		if cursor == 0 {
			return out, nil
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}
}

// ListSeats implements Store: SCAN kt:seat:* then one pipelined MGET.
func (r *Redis) ListSeats(ctx context.Context) (map[string]string, error) {
	users, err := r.scanSuffixes(ctx, "seat:")
	if err != nil {
		return nil, err
	}
	out := make(map[string]string, len(users))
	if len(users) == 0 {
		return out, nil
	}
	cmds := make([]*redis.StringCmd, len(users))
	bctx, cancel := r.bound(ctx)
	defer cancel()
	if _, err := r.client.Pipelined(bctx, func(p redis.Pipeliner) error {
		for i, userID := range users {
			cmds[i] = p.Get(bctx, r.keySeat(userID))
		}
		return nil
	}); err != nil && !errors.Is(err, redis.Nil) {
		return nil, err
	}
	for i, cmd := range cmds {
		roomID, err := cmd.Result()
		if err != nil {
			continue // expired or deleted between the scan and the read
		}
		out[users[i]] = roomID
	}
	return out, nil
}

// SeatOf implements Store.
func (r *Redis) SeatOf(ctx context.Context, userID string) (string, error) {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	roomID, err := r.client.Get(ctx, r.keySeat(userID)).Result()
	if errors.Is(err, redis.Nil) {
		return "", ErrNotFound
	}
	return roomID, err
}

// SetOnline implements Store. The hash value is "<instance>|<expiresAtMs>":
// an absolute expiry stamp (process clock + ttl) rather than the write time,
// so OnlineCount can filter with a plain comparison against now and does not
// need to know each writer's ttl.
func (r *Redis) SetOnline(ctx context.Context, userID, instance string, ttl time.Duration) error {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	expires := r.now().Add(ttl).UnixMilli()
	if ttl <= 0 {
		expires = farFuture.UnixMilli()
	}
	value := instance + "|" + strconv.FormatInt(expires, 10)
	return r.client.HSet(ctx, r.keyOnline(), userID, value).Err()
}

// SetOffline implements Store (HDEL).
func (r *Redis) SetOffline(ctx context.Context, userID string) error {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	return r.client.HDel(ctx, r.keyOnline(), userID).Err()
}

// OnlineCount implements Store (Lua: count unexpired entries, reap the rest).
func (r *Redis) OnlineCount(ctx context.Context) (int, error) {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	n, err := onlineCountScript.Run(ctx, r.client, []string{r.keyOnline()}, r.now().UnixMilli()).Int64()
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

// ---- resume offers --------------------------------------------------------

// PutResumeOffer implements Store (SET PX ttl).
func (r *Redis) PutResumeOffer(ctx context.Context, userID string, offer ResumeOffer, ttl time.Duration) error {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	body, err := json.Marshal(offer)
	if err != nil {
		return err
	}
	if ttl < 0 {
		ttl = 0
	}
	return r.client.Set(ctx, r.keyResume(userID), body, ttl).Err()
}

// TakeResumeOffer implements Store (GETDEL, atomic get-and-delete).
func (r *Redis) TakeResumeOffer(ctx context.Context, userID string) (ResumeOffer, error) {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	body, err := r.client.GetDel(ctx, r.keyResume(userID)).Bytes()
	if errors.Is(err, redis.Nil) {
		return ResumeOffer{}, ErrNotFound
	}
	if err != nil {
		return ResumeOffer{}, err
	}
	var offer ResumeOffer
	if err := json.Unmarshal(body, &offer); err != nil {
		return ResumeOffer{}, fmt.Errorf("live: corrupt resume offer for %s: %w", userID, err)
	}
	return offer, nil
}

// DeleteResumeOffer implements Store.
func (r *Redis) DeleteResumeOffer(ctx context.Context, userID string) error {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	return r.client.Del(ctx, r.keyResume(userID)).Err()
}

// ---- matchmaking index ----------------------------------------------------

// PublishTable implements Store: HSET the summary (+ PEXPIRE auxTTL) and,
// for a public table, ZADD it to its bucket scored by players — one MULTI.
// A private table is ZREMmed in case it was ever indexed.
func (r *Redis) PublishTable(ctx context.Context, t TableSummary) error {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	key := r.keySummary(t.RoomID)
	lobby := r.keyLobby(t.Category, t.BootAmount)
	_, err := r.client.TxPipelined(ctx, func(p redis.Pipeliner) error {
		p.HSet(ctx, key, summaryFields(t)...)
		p.PExpire(ctx, key, auxTTL)
		if t.IsPrivate {
			p.ZRem(ctx, lobby, t.RoomID)
		} else {
			p.ZAdd(ctx, lobby, redis.Z{Score: float64(t.Players), Member: t.RoomID})
		}
		return nil
	})
	return err
}

// RetireTable implements Store (ZREM + DEL summary, one MULTI).
func (r *Redis) RetireTable(ctx context.Context, roomID, category string, bootAmount int64) error {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	_, err := r.client.TxPipelined(ctx, func(p redis.Pipeliner) error {
		p.ZRem(ctx, r.keyLobby(category, bootAmount), roomID)
		p.Del(ctx, r.keySummary(roomID))
		return nil
	})
	return err
}

// ListSummaries implements Store: SCAN kt:summary:* then one pipelined
// HGETALL. Unlike Candidates this is not per bucket — a stray summary is
// exactly one whose bucket nobody looks in any more.
func (r *Redis) ListSummaries(ctx context.Context) ([]TableSummary, error) {
	rooms, err := r.scanSuffixes(ctx, "summary:")
	if err != nil {
		return nil, err
	}
	out := []TableSummary{}
	if len(rooms) == 0 {
		return out, nil
	}
	cmds := make([]*redis.MapStringStringCmd, len(rooms))
	bctx, cancel := r.bound(ctx)
	defer cancel()
	if _, err := r.client.Pipelined(bctx, func(p redis.Pipeliner) error {
		for i, roomID := range rooms {
			cmds[i] = p.HGetAll(bctx, r.keySummary(roomID))
		}
		return nil
	}); err != nil && !errors.Is(err, redis.Nil) {
		return nil, err
	}
	for i, cmd := range cmds {
		fields, err := cmd.Result()
		if err != nil || len(fields) == 0 {
			continue // gone between the scan and the read
		}
		summary := summaryFromFields(fields)
		if summary.RoomID == "" {
			summary.RoomID = rooms[i]
		}
		out = append(out, summary)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].RoomID < out[j].RoomID })
	return out, nil
}

// Candidates implements Store: ZREVRANGE the bucket, HGETALL every summary
// in one pipeline, drop members whose summary is gone, sort fullest first
// then oldest first. Never nil.
func (r *Redis) Candidates(ctx context.Context, category string, bootAmount int64) ([]TableSummary, error) {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	members, err := r.client.ZRevRangeWithScores(ctx, r.keyLobby(category, bootAmount), 0, -1).Result()
	if err != nil {
		return nil, err
	}
	if len(members) == 0 {
		return []TableSummary{}, nil
	}
	cmds := make([]*redis.MapStringStringCmd, len(members))
	_, err = r.client.Pipelined(ctx, func(p redis.Pipeliner) error {
		for i, z := range members {
			id, _ := z.Member.(string)
			cmds[i] = p.HGetAll(ctx, r.keySummary(id))
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	out := make([]TableSummary, 0, len(members))
	for _, cmd := range cmds {
		fields, err := cmd.Result()
		if err != nil {
			return nil, err
		}
		if len(fields) == 0 {
			continue // retired or expired between the two round trips
		}
		out = append(out, summaryFromFields(fields))
	}
	sort.Slice(out, func(i, j int) bool { return lessCandidate(out[i], out[j]) })
	return out, nil
}

// summaryFields flattens a TableSummary into HSET field/value pairs.
func summaryFields(t TableSummary) []interface{} {
	private := "0"
	if t.IsPrivate {
		private = "1"
	}
	return []interface{}{
		"roomId", t.RoomID,
		"code", t.Code,
		"category", t.Category,
		"bootAmount", strconv.FormatInt(t.BootAmount, 10),
		"players", strconv.Itoa(t.Players),
		"maxPlayers", strconv.Itoa(t.MaxPlayers),
		"isPrivate", private,
		"state", t.State,
		"createdAt", strconv.FormatInt(t.CreatedAt, 10),
		"instance", t.Instance,
	}
}

// summaryFromFields is the inverse of summaryFields; unparsable numbers read
// as zero rather than failing the whole candidate list.
func summaryFromFields(f map[string]string) TableSummary {
	atoi := func(s string) int64 {
		n, _ := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
		return n
	}
	return TableSummary{
		RoomID:     f["roomId"],
		Code:       f["code"],
		Category:   f["category"],
		BootAmount: atoi(f["bootAmount"]),
		Players:    int(atoi(f["players"])),
		MaxPlayers: int(atoi(f["maxPlayers"])),
		IsPrivate:  f["isPrivate"] == "1",
		State:      f["state"],
		CreatedAt:  atoi(f["createdAt"]),
		Instance:   f["instance"],
	}
}
