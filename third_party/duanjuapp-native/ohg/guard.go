package ohg

import (
	"context"
	"fmt"
	"sync"
	"time"
)

// ErrPlaybackCooldown 表示取流正在熔断，调用方应稍后重试。
// 它只在「上游连续返回空结果」后出现，不是设备额度问题，不要据此反复换设备。
var ErrPlaybackCooldown = fmt.Errorf("取流已暂停：上游连续返回空结果，稍后自动恢复")

// playbackGuard 是取流的节奏链与熔断器。
//
// 背景：服务端按设备计播放额度，短时间内密集取流会把额度打空并进入
// 更长的静默期。TV 端的分集网格与续播入口很容易连点，所以这里做两件事：
//   - 节奏链：相邻两次取流至少间隔 minInterval，串行执行；
//   - 熔断：连续 emptyThreshold 次空结果后暂停 cooldown，随后每次失败
//     翻倍到 maxCooldown；恢复期只放一个探测请求（半开）。
//
// minInterval 取 500ms 而非 1s：2026-11-14 创维实机连切三集，
// 1s 会把停下那一集的 resolve 从 282ms 拖到 1649ms，用户能感觉到卡顿；
// 500ms 仍能把请求频率压在 2 次/秒以内，挡住连点即可。
//
// 探测位必须在任何退出路径上释放，否则进程会永久停在「冷却中」。
// 调用方一律 defer guard.release(probe)。
type playbackGuard struct {
	mu  sync.Mutex
	now func() time.Time

	minInterval    time.Duration
	emptyThreshold int
	baseCooldown   time.Duration
	maxCooldown    time.Duration

	lastAt      time.Time
	emptyStreak int
	cooldown    time.Duration
	openUntil   time.Time
	probing     bool
}

func newPlaybackGuard() *playbackGuard {
	return &playbackGuard{
		now:            time.Now,
		minInterval:    500 * time.Millisecond,
		emptyThreshold: 3,
		baseCooldown:   30 * time.Second,
		maxCooldown:    5 * time.Minute,
		cooldown:       30 * time.Second,
	}
}

// acquire 取得一次取流许可，返回本次是否为半开期的探测请求。
// 冷却中直接返回 ErrPlaybackCooldown；需要等待节奏间隔时按 ctx 可取消地等待。
func (g *playbackGuard) acquire(ctx context.Context) (probe bool, err error) {
	if g == nil {
		return false, nil
	}
	g.mu.Lock()
	now := g.now()
	if !g.openUntil.IsZero() {
		if now.Before(g.openUntil) {
			left := g.openUntil.Sub(now).Round(time.Second)
			g.mu.Unlock()
			return false, fmt.Errorf("%w（剩余 %s）", ErrPlaybackCooldown, left)
		}
		// 冷却结束：只放一个探测，其他并发调用继续等待。
		if g.probing {
			g.mu.Unlock()
			return false, fmt.Errorf("%w（正在探测）", ErrPlaybackCooldown)
		}
		g.probing = true
		probe = true
	}
	wait := time.Duration(0)
	if !g.lastAt.IsZero() && g.minInterval > 0 {
		if d := g.lastAt.Add(g.minInterval).Sub(now); d > 0 {
			wait = d
		}
	}
	// 预占未来时隙，避免并发调用算出同一个起点。
	g.lastAt = now.Add(wait)
	g.mu.Unlock()

	if wait > 0 {
		timer := time.NewTimer(wait)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return probe, ctx.Err()
		case <-timer.C:
		}
	}
	return probe, nil
}

// reportOK 记录一次成功取流，复位熔断等级。
func (g *playbackGuard) reportOK() {
	if g == nil {
		return
	}
	g.mu.Lock()
	g.emptyStreak = 0
	g.cooldown = g.baseCooldown
	g.openUntil = time.Time{}
	g.probing = false
	g.mu.Unlock()
}

// reportEmpty 记录一次空结果。达到阈值后开启冷却，并把下次冷却时长翻倍。
func (g *playbackGuard) reportEmpty() {
	if g == nil {
		return
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.probing = false
	g.emptyStreak++
	if g.emptyStreak < g.emptyThreshold {
		return
	}
	g.emptyStreak = 0
	g.openUntil = g.now().Add(g.cooldown)
	if next := g.cooldown * 2; next <= g.maxCooldown {
		g.cooldown = next
	}
}

// release 幂等释放探测位。只有真正拿到探测权的调用需要它。
func (g *playbackGuard) release(probe bool) {
	if g == nil || !probe {
		return
	}
	g.mu.Lock()
	g.probing = false
	g.mu.Unlock()
}

// cooling 报告当前是否处于冷却期，仅供诊断使用。
func (g *playbackGuard) cooling() bool {
	if g == nil {
		return false
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	return !g.openUntil.IsZero() && g.now().Before(g.openUntil)
}
