package app

import (
	"math"
	"os"
	"runtime"
	"runtime/metrics"
	"strconv"
	"strings"
	"sync"
	"time"
)

// runtime/metrics samples the vitals reader takes in one batch.
const (
	sampleSchedLatencies = "/sched/latencies:seconds"
	sampleHeapObjects    = "/memory/classes/heap/objects:bytes"
	sampleHeapUnused     = "/memory/classes/heap/unused:bytes"
	sampleHeapFree       = "/memory/classes/heap/free:bytes"
	sampleHeapReleased   = "/memory/classes/heap/released:bytes"
	sampleTotalMemory    = "/memory/classes/total:bytes"
	sampleGoroutines     = "/sched/goroutines:goroutines"
)

// vitals is the state behind /health.process (index.js:40-43): the CPU and
// scheduler-latency marks are taken per call, so every reading covers the
// interval since the PREVIOUS /health call — Node re-marked process.cpuUsage
// and reset its monitorEventLoopDelay histogram the same way. Two pollers
// interleaving see each other's intervals, exactly as in Node.
type vitals struct {
	mu          sync.Mutex
	lastAt      time.Time
	lastCPU     time.Duration // user + system at the previous call
	lastSched   []uint64      // cumulative /sched/latencies counts at the previous call
	lastAcquire int64         // pgxpool EmptyAcquireCount at the previous call
	samples     []metrics.Sample
}

func newVitals(now time.Time) *vitals {
	v := &vitals{lastAt: now}
	v.samples = []metrics.Sample{
		{Name: sampleSchedLatencies}, {Name: sampleHeapObjects}, {Name: sampleHeapUnused},
		{Name: sampleHeapFree}, {Name: sampleHeapReleased}, {Name: sampleTotalMemory}, {Name: sampleGoroutines},
	}
	// Prime the marks so the first /health reports "since start", as Node did.
	cpu, _ := processCPUTime()
	v.lastCPU = cpu
	metrics.Read(v.samples)
	if h := v.histogram(sampleSchedLatencies); h != nil {
		v.lastSched = append([]uint64(nil), h.Counts...)
	}
	return v
}

func (v *vitals) histogram(name string) *metrics.Float64Histogram {
	for _, s := range v.samples {
		if s.Name == name && s.Value.Kind() == metrics.KindFloat64Histogram {
			return s.Value.Float64Histogram()
		}
	}
	return nil
}

func (v *vitals) uint64(name string) uint64 {
	for _, s := range v.samples {
		if s.Name == name && s.Value.Kind() == metrics.KindUint64 {
			return s.Value.Uint64()
		}
	}
	return 0
}

// read produces /health.process, re-marking CPU and scheduler latency.
// emptyAcquire is the pool's cumulative EmptyAcquireCount (or -1 when there
// is no pool); the returned waiting figure is its delta since the last call.
func (v *vitals) read(now time.Time, emptyAcquire int64) (ProcessHealth, int) {
	v.mu.Lock()
	defer v.mu.Unlock()

	metrics.Read(v.samples)

	// CPU: (user+system since the previous call) / wall elapsed × 100, 1 dp;
	// 0 when no time has elapsed (Node: elapsedUs > 0 ? … : 0).
	cpuPercent := 0.0
	if cpu, ok := processCPUTime(); ok {
		elapsed := now.Sub(v.lastAt)
		if elapsed > 0 {
			cpuPercent = round1(float64(cpu-v.lastCPU) / float64(elapsed) * 100)
			if cpuPercent < 0 {
				cpuPercent = 0
			}
		}
		v.lastCPU = cpu
	}
	v.lastAt = now

	// Scheduler latency since the previous call: the delta of the cumulative
	// runtime histogram (DECISIONS.md §5 — Go's stand-in for event-loop lag).
	var p50, p99, max float64
	if h := v.histogram(sampleSchedLatencies); h != nil {
		delta := make([]uint64, len(h.Counts))
		for i, c := range h.Counts {
			if i < len(v.lastSched) && v.lastSched[i] <= c {
				delta[i] = c - v.lastSched[i]
			} else {
				delta[i] = c
			}
		}
		v.lastSched = append(v.lastSched[:0], h.Counts...)
		p50, p99, max = histogramPercentiles(h.Buckets, delta)
	}

	waiting := 0
	if emptyAcquire >= 0 {
		if emptyAcquire >= v.lastAcquire {
			waiting = int(emptyAcquire - v.lastAcquire)
		}
		v.lastAcquire = emptyAcquire
	}

	heapUsed := v.uint64(sampleHeapObjects)
	heapTotal := heapUsed + v.uint64(sampleHeapUnused) + v.uint64(sampleHeapFree) + v.uint64(sampleHeapReleased)
	rss, ok := residentBytes()
	if !ok {
		rss = v.uint64(sampleTotalMemory)
	}

	return ProcessHealth{
		PID:          os.Getpid(),
		Node:         runtime.Version(),
		RSSMb:        mb(rss),
		HeapUsedMb:   mb(heapUsed),
		HeapTotalMb:  mb(heapTotal),
		ExternalMb:   0,
		CPUPercent:   cpuPercent,
		LoopLagP50Ms: ms(p50),
		LoopLagP99Ms: ms(p99),
		LoopLagMaxMs: ms(max),
		Goroutines:   int(v.uint64(sampleGoroutines)),
		NumCPU:       runtime.NumCPU(),
		GOMAXPROCS:   runtime.GOMAXPROCS(0),
	}, waiting
}

// histogramPercentiles reads p50, p99 and the max (seconds) out of a
// runtime/metrics histogram delta. Each percentile reports the upper bound of
// the bucket in which the cumulative count crosses it; the open-ended last
// bucket reports its lower bound. No samples → zeros.
func histogramPercentiles(buckets []float64, counts []uint64) (p50, p99, max float64) {
	var total uint64
	for _, c := range counts {
		total += c
	}
	if total == 0 || len(buckets) != len(counts)+1 {
		return 0, 0, 0
	}
	upper := func(i int) float64 {
		u := buckets[i+1]
		if math.IsInf(u, 1) {
			return buckets[i]
		}
		return u
	}
	t50 := uint64(math.Ceil(float64(total) * 0.50))
	t99 := uint64(math.Ceil(float64(total) * 0.99))
	var cum uint64
	got50, got99 := false, false
	for i, c := range counts {
		if c == 0 {
			continue
		}
		cum += c
		if !got50 && cum >= t50 {
			p50, got50 = upper(i), true
		}
		if !got99 && cum >= t99 {
			p99, got99 = upper(i), true
		}
		max = upper(i)
	}
	return p50, p99, max
}

// mb is Node's `Math.round(bytes / 1048576 * 10) / 10`.
func mb(bytes uint64) float64 { return round1(float64(bytes) / 1048576) }

// ms is Node's `ns(v)` with the input already in seconds: milliseconds, 1 dp.
func ms(seconds float64) float64 { return round1(seconds * 1000) }

func round1(x float64) float64 {
	if math.IsNaN(x) || math.IsInf(x, 0) {
		return 0
	}
	return math.Round(x*10) / 10
}

// residentBytes reads the process RSS from /proc/self/statm (resident pages ×
// page size) — what process.memoryUsage().rss reported. ok is false where
// procfs is unavailable; the caller falls back to Go's mapped-memory total.
func residentBytes() (uint64, bool) {
	raw, err := os.ReadFile("/proc/self/statm")
	if err != nil {
		return 0, false
	}
	fields := strings.Fields(string(raw))
	if len(fields) < 2 {
		return 0, false
	}
	pages, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		return 0, false
	}
	return pages * uint64(os.Getpagesize()), true
}
