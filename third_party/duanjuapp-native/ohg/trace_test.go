package ohg

import (
	"context"
	"strconv"
	"strings"
	"testing"

	"duanjuapp/native/ohg/sdk"
)

// fakeStore 只统计 Reset 被调用了几次，用来验证 countStore 的计数。
type fakeStore struct {
	resets  int
	profile *sdk.DeviceProfile
}

func (s *fakeStore) Load(ctx context.Context) (*sdk.DeviceProfile, error) {
	if s.profile == nil {
		return nil, sdk.ErrProfileNotFound
	}
	return s.profile, nil
}

func (s *fakeStore) Save(ctx context.Context, p *sdk.DeviceProfile) error {
	s.profile = p
	return nil
}

func (s *fakeStore) Reset(ctx context.Context) error {
	s.resets++
	s.profile = nil
	return nil
}

func TestCountStoreTracksResets(t *testing.T) {
	trace := &traceLog{}
	store := countStore{inner: &fakeStore{}, trace: trace}
	ctx := context.Background()

	if got := trace.rotations(); got != 0 {
		t.Fatalf("fresh trace rotations = %d, want 0", got)
	}
	for i := 1; i <= 2; i++ {
		if err := store.Reset(ctx); err != nil {
			t.Fatalf("reset #%d: %v", i, err)
		}
		if got := trace.rotations(); got != i {
			t.Fatalf("after %d resets rotations = %d, want %d", i, got, i)
		}
	}

	// begin 必须把计数清零，否则下一次取流会继承上一次的数字。
	trace.begin()
	if got := trace.rotations(); got != 0 {
		t.Fatalf("begin did not clear rotations: %d", got)
	}
}

func TestTraceLogKeepsNewestLines(t *testing.T) {
	const total = traceLines + 4
	trace := &traceLog{}
	for i := 0; i < total; i++ {
		trace.Printf("line %d", i)
	}
	trace.countReset()
	summary := trace.summary()

	if !strings.Contains(summary, "换设备 1 次") {
		t.Fatalf("summary missing rotation count: %q", summary)
	}
	// 只保留最近 traceLines 行：最早的那几行必须已经滚掉。
	if strings.Contains(summary, "line 3;") {
		t.Fatalf("summary kept a line older than the window: %q", summary)
	}
	for _, want := range []string{"line 4;", "line " + strconv.Itoa(total-1)} {
		if !strings.Contains(summary, want) {
			t.Fatalf("summary missing %q: %q", want, summary)
		}
	}
}
