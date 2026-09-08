package live

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
)

// BenchmarkSaveTable measures one CAS save of a 20 KB snapshot per backend:
//
//	go test -run '^$' -bench SaveTable -benchmem ./internal/live/
//
// The real-redis variant runs only with REDIS_TEST_URL set (a benchmark
// cannot start the server for itself the way the tests do).
func BenchmarkSaveTable(b *testing.B) {
	snap := bigSnapshot("bench-hand", 20*1024)
	run := func(b *testing.B, store Store) {
		ctx := context.Background()
		b.SetBytes(int64(len(snap)))
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if err := store.SaveTable(ctx, "bench", int64(i+1), snap, 24*time.Hour); err != nil {
				b.Fatal(err)
			}
		}
	}
	b.Run("memory", func(b *testing.B) {
		store := NewMemory()
		defer store.Close()
		run(b, store)
	})
	b.Run("miniredis", func(b *testing.B) {
		m := miniredis.RunT(b)
		store, err := OpenRedis(context.Background(), Options{URL: "redis://" + m.Addr(), KeyPrefix: "b:"})
		if err != nil {
			b.Fatal(err)
		}
		defer store.Close()
		run(b, store)
	})
	b.Run("redis", func(b *testing.B) {
		url := os.Getenv("REDIS_TEST_URL")
		if url == "" {
			b.Skip("set REDIS_TEST_URL to benchmark against a real server")
		}
		store, err := OpenRedis(context.Background(), Options{URL: url, KeyPrefix: "bench:" + time.Now().Format("150405") + ":"})
		if err != nil {
			b.Fatal(err)
		}
		defer func() {
			_ = store.DeleteTable(context.Background(), "bench")
			_ = store.Close()
		}()
		run(b, store)
	})
}

// BenchmarkHandIDOf is the per-save cost of pulling hand.id out of the
// snapshot for the Redis hash.
func BenchmarkHandIDOf(b *testing.B) {
	snap := bigSnapshot("bench-hand", 20*1024)
	b.SetBytes(int64(len(snap)))
	for i := 0; i < b.N; i++ {
		if HandIDOf(snap) != "bench-hand" {
			b.Fatal("wrong hand id")
		}
	}
}
