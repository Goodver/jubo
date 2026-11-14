package ohg

import (
	"context"
	"errors"
	"testing"
	"time"
)

func newTestGuard(now time.Time) (*playbackGuard, *time.Time) {
	g := newPlaybackGuard()
	clock := now
	g.now = func() time.Time { return clock }
	g.minInterval = 0
	return g, &clock
}

func TestGuardOpensCooldownAfterConsecutiveEmpty(t *testing.T) {
	ctx := context.Background()
	g, clock := newTestGuard(time.Unix(1000, 0))

	for i := 0; i < 3; i++ {
		probe, err := g.acquire(ctx)
		if err != nil {
			t.Fatalf("attempt %d: %v", i, err)
		}
		g.release(probe)
		g.reportEmpty()
	}

	if _, err := g.acquire(ctx); !errors.Is(err, ErrPlaybackCooldown) {
		t.Fatalf("expected cooldown, got %v", err)
	}

	// 冷却期满后只放一个探测请求。
	*clock = clock.Add(31 * time.Second)
	probe, err := g.acquire(ctx)
	if err != nil {
		t.Fatalf("half-open acquire: %v", err)
	}
	if !probe {
		t.Fatal("expected half-open acquire to be marked as probe")
	}
	if _, err := g.acquire(ctx); !errors.Is(err, ErrPlaybackCooldown) {
		t.Fatalf("second half-open acquire should be rejected, got %v", err)
	}

	// 探测成功后熔断复位，随后恢复正常放行。
	g.release(probe)
	g.reportOK()
	if _, err := g.acquire(ctx); err != nil {
		t.Fatalf("after recovery: %v", err)
	}
}

func TestGuardCooldownDoublesUpToMax(t *testing.T) {
	ctx := context.Background()
	g, clock := newTestGuard(time.Unix(2000, 0))
	g.maxCooldown = 2 * time.Minute

	open := func() time.Duration {
		for i := 0; i < g.emptyThreshold; i++ {
			probe, err := g.acquire(ctx)
			if err != nil {
				t.Fatalf("acquire: %v", err)
			}
			g.release(probe)
			g.reportEmpty()
		}
		d := g.openUntil.Sub(*clock)
		// 跳过本轮冷却，进入下一轮。
		*clock = g.openUntil.Add(time.Second)
		return d
	}

	first := open()
	second := open()
	third := open()
	fourth := open()

	if first != 30*time.Second {
		t.Fatalf("first cooldown = %v, want 30s", first)
	}
	if second != time.Minute {
		t.Fatalf("second cooldown = %v, want 1m", second)
	}
	if third != 2*time.Minute {
		t.Fatalf("third cooldown = %v, want 2m", third)
	}
	if fourth != 2*time.Minute {
		t.Fatalf("fourth cooldown = %v, want cap at 2m", fourth)
	}
}

func TestGuardReleaseAlwaysClearsProbe(t *testing.T) {
	ctx := context.Background()
	g, clock := newTestGuard(time.Unix(3000, 0))

	for i := 0; i < 3; i++ {
		probe, err := g.acquire(ctx)
		if err != nil {
			t.Fatalf("acquire: %v", err)
		}
		g.release(probe)
		g.reportEmpty()
	}
	*clock = clock.Add(31 * time.Second)

	probe, err := g.acquire(ctx)
	if err != nil || !probe {
		t.Fatalf("probe acquire: %v", err)
	}
	// 模拟异常退出路径：只调 release，不 report。探测位必须被清掉。
	g.release(probe)

	g.mu.Lock()
	leaked := g.probing
	g.mu.Unlock()
	if leaked {
		t.Fatal("probe slot leaked after release")
	}

	*clock = clock.Add(31 * time.Second)
	if _, err := g.acquire(ctx); err != nil {
		t.Fatalf("probe slot leaked, next acquire failed: %v", err)
	}
}

func TestGuardEnforcesMinInterval(t *testing.T) {
	ctx := context.Background()
	g := newPlaybackGuard()
	g.minInterval = 40 * time.Millisecond

	probe, err := g.acquire(ctx)
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}
	g.release(probe)

	start := time.Now()
	probe, err = g.acquire(ctx)
	if err != nil {
		t.Fatalf("second acquire: %v", err)
	}
	g.release(probe)
	if elapsed := time.Since(start); elapsed < 30*time.Millisecond {
		t.Fatalf("min interval not enforced, waited %v", elapsed)
	}
}

func TestGuardAcquireRespectsContextCancel(t *testing.T) {
	g := newPlaybackGuard()
	g.minInterval = time.Hour

	probe, err := g.acquire(context.Background())
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}
	g.release(probe)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, err := g.acquire(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected deadline exceeded, got %v", err)
	}
}
