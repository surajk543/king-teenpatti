package live

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/redis/go-redis/v9"
)

// The players' statistics on Redis (Player stats v2; the key layout is in
// stats.go):
//
//	kt:stats:<userId>                    hash  pending counters, HINCRBY / a max
//	kt:stats:dirty                       set   players with pending counters
//	kt:stats:batches                     zset  open batch ids, scored by when taken
//	kt:stats:batch:<batchId>             set   the players a batch holds
//	kt:stats:inflight:<batchId>:<userId> hash  a player's counters as the batch took them
//
// None of them expires: a counter lives until the flusher has put it in
// PostgreSQL (or the account is deleted).

func (r *Redis) keyStats(userID string) string { return r.prefix + "stats:" + userID }
func (r *Redis) keyStatsDirty() string         { return r.prefix + "stats:dirty" }
func (r *Redis) keyStatsBatches() string       { return r.prefix + "stats:batches" }
func (r *Redis) keyStatsBatch(batchID string) string {
	return r.prefix + "stats:batch:" + batchID
}
func (r *Redis) keyStatsInflight(batchID, userID string) string {
	return r.prefix + "stats:inflight:" + batchID + ":" + userID
}

// recordStatsScript folds a whole hand's deltas in, atomically.
//
//	KEYS[1]     = kt:stats:dirty
//	KEYS[1 + i] = kt:stats:<userId> of delta i
//	ARGV        = for each delta, in KEYS order: userId, nAdd, nMax, then nAdd
//	              (field, value) pairs to HINCRBY, then nMax (field, value)
//	              pairs to keep at the larger
//
// A Max field is compared as a Lua number (a double: exact below 2^53, which
// no pot comes near) and written back as the caller's own digits. Returns the
// number of deltas folded in.
var recordStatsScript = redis.NewScript(`
local pos = 1
for i = 2, #KEYS do
  local key = KEYS[i]
  local user = ARGV[pos]
  local nadd = tonumber(ARGV[pos + 1])
  local nmax = tonumber(ARGV[pos + 2])
  pos = pos + 3
  for j = 1, nadd do
    redis.call('HINCRBY', key, ARGV[pos], ARGV[pos + 1])
    pos = pos + 2
  end
  for j = 1, nmax do
    local cur = redis.call('HGET', key, ARGV[pos])
    if (not cur) or tonumber(ARGV[pos + 1]) > tonumber(cur) then
      redis.call('HSET', key, ARGV[pos], ARGV[pos + 1])
    end
    pos = pos + 2
  end
  redis.call('SADD', KEYS[1], user)
end
return #KEYS - 1
`)

// takeStatsBatchScript moves candidate players' pending hashes into a batch,
// atomically: a delta recorded after it lands in a fresh pending hash.
//
//	KEYS[1]      = kt:stats:dirty
//	KEYS[2]      = kt:stats:batches
//	KEYS[3]      = kt:stats:batch:<batchId>
//	KEYS[2 + 2i] = kt:stats:<userId_i>
//	KEYS[3 + 2i] = kt:stats:inflight:<batchId>:<userId_i>
//	ARGV[1]      = batchId   ARGV[2] = taken at (epoch ms)   ARGV[2 + i] = userId_i
//
// A candidate is moved only if it is still dirty (SREM says 1 — another
// flusher may have taken it since it was picked) and still has a pending
// hash; the hash is RENAMEd, which is O(1) whatever its size. The batch is
// indexed only when it holds somebody. Returns {userId, {field, value, …}, …}
// for every player moved; refuses a batch id already open.
var takeStatsBatchScript = redis.NewScript(`
if redis.call('ZSCORE', KEYS[2], ARGV[1]) then
  return redis.error_reply('stats batch exists')
end
local out = {}
for i = 1, #ARGV - 2 do
  local user = ARGV[2 + i]
  if redis.call('SREM', KEYS[1], user) == 1 then
    local pending, flight = KEYS[2 + 2 * i], KEYS[3 + 2 * i]
    if redis.call('EXISTS', pending) == 1 then
      local fields = redis.call('HGETALL', pending)
      redis.call('RENAME', pending, flight)
      redis.call('SADD', KEYS[3], user)
      out[#out + 1] = user
      out[#out + 1] = fields
    end
  end
end
if #out > 0 then
  redis.call('ZADD', KEYS[2], ARGV[2], ARGV[1])
end
return out
`)

// RecordStats implements Store: one EVALSHA (recordStatsScript) for every
// delta of the call.
func (r *Redis) RecordStats(ctx context.Context, deltas []StatsDelta) error {
	keys := []string{r.keyStatsDirty()}
	var args []interface{}
	for _, d := range deltas {
		if d.empty() {
			continue
		}
		keys = append(keys, r.keyStats(d.UserID))
		args = append(args, d.UserID, len(d.Add), len(d.Max))
		for _, field := range sortedFieldNames(d.Add) {
			args = append(args, field, d.Add[field])
		}
		for _, field := range sortedFieldNames(d.Max) {
			args = append(args, field, d.Max[field])
		}
	}
	if len(keys) == 1 {
		return nil
	}
	ctx, cancel := r.bound(ctx)
	defer cancel()
	return recordStatsScript.Run(ctx, r.client, keys, args...).Err()
}

// TakeStatsBatch implements Store: SRANDMEMBER picks up to max dirty
// players, then takeStatsBatchScript moves those still dirty — two round
// trips, the move itself atomic.
func (r *Redis) TakeStatsBatch(ctx context.Context, batchID string, max int) (StatsBatch, error) {
	out := StatsBatch{ID: batchID, CreatedAt: r.now().UnixMilli(), Players: map[string]map[string]int64{}}
	if max <= 0 {
		return out, nil
	}
	ctx, cancel := r.bound(ctx)
	defer cancel()
	candidates, err := r.client.SRandMemberN(ctx, r.keyStatsDirty(), int64(max)).Result()
	if err != nil {
		return StatsBatch{}, err
	}
	if len(candidates) == 0 {
		return out, nil
	}
	keys := []string{r.keyStatsDirty(), r.keyStatsBatches(), r.keyStatsBatch(batchID)}
	args := []interface{}{batchID, out.CreatedAt}
	for _, userID := range candidates {
		keys = append(keys, r.keyStats(userID), r.keyStatsInflight(batchID, userID))
		args = append(args, userID)
	}
	res, err := takeStatsBatchScript.Run(ctx, r.client, keys, args...).Slice()
	if err != nil {
		if strings.Contains(err.Error(), "stats batch exists") {
			return StatsBatch{}, ErrStatsBatchExists
		}
		return StatsBatch{}, err
	}
	for i := 0; i+1 < len(res); i += 2 {
		userID, _ := res[i].(string)
		pairs, _ := res[i+1].([]interface{})
		fields, err := statsFieldsFromPairs(pairs)
		if err != nil {
			return StatsBatch{}, fmt.Errorf("live: stats batch %s, player %s: %w", batchID, userID, err)
		}
		out.Players[userID] = fields
	}
	return out, nil
}

// StatsBatches implements Store: ZRANGE the index, then one pipeline of
// SMEMBERS and one of HGETALL — three round trips, and one when no batch is
// open, which is every pass but the rare one after a failure.
func (r *Redis) StatsBatches(ctx context.Context) ([]StatsBatch, error) {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	index, err := r.client.ZRangeWithScores(ctx, r.keyStatsBatches(), 0, -1).Result()
	if err != nil {
		return nil, err
	}
	out := make([]StatsBatch, 0, len(index))
	if len(index) == 0 {
		return out, nil
	}
	members := make([]*redis.StringSliceCmd, len(index))
	if _, err := r.client.Pipelined(ctx, func(p redis.Pipeliner) error {
		for i, z := range index {
			id, _ := z.Member.(string)
			members[i] = p.SMembers(ctx, r.keyStatsBatch(id))
		}
		return nil
	}); err != nil {
		return nil, err
	}
	type slot struct {
		batch, user string
		cmd         *redis.MapStringStringCmd
	}
	var slots []slot
	if _, err := r.client.Pipelined(ctx, func(p redis.Pipeliner) error {
		for i, z := range index {
			id, _ := z.Member.(string)
			for _, userID := range members[i].Val() {
				slots = append(slots, slot{batch: id, user: userID, cmd: p.HGetAll(ctx, r.keyStatsInflight(id, userID))})
			}
		}
		return nil
	}); err != nil {
		return nil, err
	}
	byID := make(map[string]*StatsBatch, len(index))
	for _, z := range index {
		id, _ := z.Member.(string)
		out = append(out, StatsBatch{ID: id, CreatedAt: int64(z.Score), Players: map[string]map[string]int64{}})
	}
	for i := range out {
		byID[out[i].ID] = &out[i]
	}
	for _, s := range slots {
		raw, err := s.cmd.Result()
		if err != nil || len(raw) == 0 {
			continue // finished between the reads, or a member whose hash is gone
		}
		fields, err := statsFieldsFromMap(raw)
		if err != nil {
			return nil, fmt.Errorf("live: stats batch %s, player %s: %w", s.batch, s.user, err)
		}
		byID[s.batch].Players[s.user] = fields
	}
	return out, nil
}

// FinishStatsBatch implements Store: SMEMBERS, then one MULTI deleting every
// in-flight hash, the member set and the index entry.
func (r *Redis) FinishStatsBatch(ctx context.Context, batchID string) error {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	users, err := r.client.SMembers(ctx, r.keyStatsBatch(batchID)).Result()
	if err != nil {
		return err
	}
	_, err = r.client.TxPipelined(ctx, func(p redis.Pipeliner) error {
		if len(users) > 0 {
			keys := make([]string, 0, len(users))
			for _, userID := range users {
				keys = append(keys, r.keyStatsInflight(batchID, userID))
			}
			p.Del(ctx, keys...)
		}
		p.Del(ctx, r.keyStatsBatch(batchID))
		p.ZRem(ctx, r.keyStatsBatches(), batchID)
		return nil
	})
	return err
}

// DropStats implements Store: DEL the pending hash and SREM the dirty mark,
// one MULTI.
func (r *Redis) DropStats(ctx context.Context, userID string) error {
	ctx, cancel := r.bound(ctx)
	defer cancel()
	_, err := r.client.TxPipelined(ctx, func(p redis.Pipeliner) error {
		p.Del(ctx, r.keyStats(userID))
		p.SRem(ctx, r.keyStatsDirty(), userID)
		return nil
	})
	return err
}

// sortedFieldNames lists a delta's fields in order, so a script's arguments
// are the same for the same delta.
func sortedFieldNames(m map[string]int64) []string {
	out := make([]string, 0, len(m))
	for field := range m {
		out = append(out, field)
	}
	sort.Strings(out)
	return out
}

// statsFieldsFromPairs reads an HGETALL reply as a script returns it: field,
// value, field, value.
func statsFieldsFromPairs(pairs []interface{}) (map[string]int64, error) {
	out := make(map[string]int64, len(pairs)/2)
	for i := 0; i+1 < len(pairs); i += 2 {
		field, _ := pairs[i].(string)
		raw, _ := pairs[i+1].(string)
		v, err := strconv.ParseInt(raw, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("field %s: %w", field, err)
		}
		out[field] = v
	}
	return out, nil
}

// statsFieldsFromMap reads an HGETALL reply.
func statsFieldsFromMap(raw map[string]string) (map[string]int64, error) {
	out := make(map[string]int64, len(raw))
	for field, s := range raw {
		v, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("field %s: %w", field, err)
		}
		out[field] = v
	}
	return out, nil
}
