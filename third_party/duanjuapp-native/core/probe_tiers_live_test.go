//go:build live

package core

import (
	"context"
	"strings"
	"testing"
	"time"
)

// 逐级排查三级取流链路，找出仍可用的通路。
//
//	go test -tags live ./core/ -run TestLiveTiers -v -timeout 300s
func TestLiveTiers(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()

	// 用手机上正在失败的剧（series id 来自 app 日志）
	seriesID := "7700968020511837208"
	title, chapters, err := d.fetchHongguoChapters(ctx, seriesID)
	if err != nil {
		t.Fatalf("章节获取失败（这一步本身也是签名接口）: %v", err)
	}
	t.Logf("剧名=%s 集数=%d", title, len(chapters))
	if len(chapters) == 0 {
		t.Fatal("无章节")
	}

	for i := 0; i < 3 && i < len(chapters); i++ {
		vid := strings.TrimPrefix(chapters[i].VideoURL, "hongguo-cenc://")
		t.Logf("--- 第%d集 vid=%s ---", i+1, vid)

		m1, e1 := d.resolveHongguoAppMedia(ctx, vid)
		if e1 == nil {
			t.Logf("  [App] OK quality=%d dur=%v url=%.90s", m1.Quality, m1.Duration, m1.URL)
		} else {
			t.Logf("  [App] FAIL %v", publicError(e1))
		}

		m2, e2 := d.resolveHongguoWebMedia(ctx, seriesID, vid)
		if e2 == nil {
			t.Logf("  [Web] OK dur=%v url=%.90s", m2.Duration, m2.URL)
		} else {
			t.Logf("  [Web] FAIL %v", publicError(e2))
		}

		m3, e3 := d.resolveHongguoPlaybackAPI(ctx, seriesID, vid)
		if e3 == nil {
			t.Logf("  [API] OK quality=%d dur=%v url=%.90s", m3.Quality, m3.Duration, m3.URL)
		} else {
			t.Logf("  [API] FAIL %v", publicError(e3))
		}
	}
}
