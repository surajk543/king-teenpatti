package live

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
)

// The players' statistics' keys on Redis are the contract with operators
// (Player stats v2; stats.go): the pending hash per player, the dirty set,
// and a batch's index entry, member set and in-flight hashes.
func TestRedisStatsKeyLayout(t *testing.T) {
	ctx := context.Background()
	m := miniredis.RunT(t)
	r := openRedisStore(t, "redis://"+m.Addr(), "kt:")
	before := time.Now().UnixMilli()

	must(t, r.RecordStats(ctx, []StatsDelta{{UserID: "user1",
		Add: map[string]int64{"TEEN_PATTI:hands_played": 1, "VARIATION:v:MUFLIS:played": 1},
		Max: map[string]int64{"TEEN_PATTI:biggest_pot": 900}}}))
	if got := m.HGet("kt:stats:user1", "TEEN_PATTI:hands_played"); got != "1" {
		t.Fatalf("kt:stats:user1 TEEN_PATTI:hands_played = %q", got)
	}
	if got := m.HGet("kt:stats:user1", "TEEN_PATTI:biggest_pot"); got != "900" {
		t.Fatalf("kt:stats:user1 TEEN_PATTI:biggest_pot = %q", got)
	}
	if got := m.HGet("kt:stats:user1", "VARIATION:v:MUFLIS:played"); got != "1" {
		t.Fatalf("kt:stats:user1 VARIATION:v:MUFLIS:played = %q", got)
	}
	dirty, err := m.SMembers("kt:stats:dirty")
	must(t, err)
	if strings.Join(dirty, ",") != "user1" {
		t.Fatalf("kt:stats:dirty = %v", dirty)
	}
	if ttl := m.TTL("kt:stats:user1"); ttl != 0 {
		t.Fatalf("a pending hash expires (%v): it must live until it is flushed", ttl)
	}

	batch, err := r.TakeStatsBatch(ctx, "batch1", 500)
	must(t, err)
	if len(batch.Players) != 1 || batch.CreatedAt < before {
		t.Fatalf("batch = %+v", batch)
	}
	if m.Exists("kt:stats:user1") {
		t.Fatal("the pending hash was not moved out")
	}
	if got := m.HGet("kt:stats:inflight:batch1:user1", "TEEN_PATTI:hands_played"); got != "1" {
		t.Fatalf("kt:stats:inflight:batch1:user1 = %q", got)
	}
	members, err := m.SMembers("kt:stats:batch:batch1")
	must(t, err)
	if strings.Join(members, ",") != "user1" {
		t.Fatalf("kt:stats:batch:batch1 = %v", members)
	}
	if score, err := m.ZScore("kt:stats:batches", "batch1"); err != nil || int64(score) < before {
		t.Fatalf("kt:stats:batches batch1 = %v (%v)", score, err)
	}
	if dirty, _ := m.SMembers("kt:stats:dirty"); len(dirty) != 0 {
		t.Fatalf("kt:stats:dirty after the take = %v", dirty)
	}

	must(t, r.FinishStatsBatch(ctx, "batch1"))
	for _, key := range []string{"kt:stats:inflight:batch1:user1", "kt:stats:batch:batch1"} {
		if m.Exists(key) {
			t.Fatalf("%s survives the finish", key)
		}
	}
	if m.Exists("kt:stats:batches") {
		if n, _ := m.ZMembers("kt:stats:batches"); len(n) != 0 {
			t.Fatalf("kt:stats:batches still lists %v", n)
		}
	}
}
