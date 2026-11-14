package ohg

import (
	"context"
	"fmt"
	"strings"
	"sync"

	"duanjuapp/native/ohg/sdk"
)

// traceLines 限制随错误一起带出的日志行数，避免把整段日志塞进错误串。
const traceLines = 8

// traceLog 收集 SDK 的诊断输出与本次取流实际换了几台设备。
//
// 引擎在 Android 上没有日志通道：Go 侧的 Logger 不会进 logcat，core 也没有
// 日志设施。所以取流失败时唯一能让现场可见的出口就是错误本身 —— Dart 的失败
// 分支会把错误打印到 logcat。
//
// 有了这两项，才能区分两种修法完全相反的故障：
//   - 换设备 0 次：重试根本没跑，问题在错误分类，不在额度；
//   - 换设备 2 次仍失败：重试跑了但新设备也被判空，要改的是轮换策略。
type traceLog struct {
	mu     sync.Mutex
	lines  []string
	resets int
}

// begin 清空上一次调用的痕迹。引擎的取流是串行的，所以一份痕迹就够。
func (t *traceLog) begin() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.lines = t.lines[:0]
	t.resets = 0
}

// Printf 实现 sdk.Logger。只保留最近 traceLines 行。
func (t *traceLog) Printf(format string, args ...any) {
	line := strings.TrimSpace(fmt.Sprintf(format, args...))
	if line == "" {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if len(t.lines) >= traceLines {
		copy(t.lines, t.lines[1:])
		t.lines = t.lines[:len(t.lines)-1]
	}
	t.lines = append(t.lines, line)
}

// countReset 由 countStore 在档案被成功删除时调用。
func (t *traceLog) countReset() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.resets++
}

// rotations 返回本次取流换过几台设备。
func (t *traceLog) rotations() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.resets
}

// summary 生成一行诊断，附在取流失败的错误后面。
func (t *traceLog) summary() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	parts := []string{fmt.Sprintf("换设备 %d 次", t.resets)}
	if len(t.lines) > 0 {
		parts = append(parts, strings.Join(t.lines, "; "))
	}
	return strings.Join(parts, "；")
}

// countStore 包一层 ProfileStore，统计 SDK 实际执行了几次换设备。
//
// 不靠解析日志行来判断：换设备的文案随时可能改，而 Reset 是确定的动作。
type countStore struct {
	inner sdk.ProfileStore
	trace *traceLog
}

func (s countStore) Load(ctx context.Context) (*sdk.DeviceProfile, error) {
	return s.inner.Load(ctx)
}

func (s countStore) Save(ctx context.Context, profile *sdk.DeviceProfile) error {
	return s.inner.Save(ctx, profile)
}

func (s countStore) Reset(ctx context.Context) error {
	if err := s.inner.Reset(ctx); err != nil {
		return err
	}
	s.trace.countReset()
	return nil
}
