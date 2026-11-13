//go:build live

package core

import (
	"context"
	"strings"
	"testing"
	"time"
)

// 用手机上失败的剧，取真实 vid 后走完整取流链路（含新的设备健康度逻辑）。
//
//	go test -tags live ./core/ -run TestLiveRealVids -v -timeout 300s
func TestLiveRealVids(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Second)
	defer cancel()

	series := []string{
		"7701272618531310617", // 备用联系人（app 当前失败的那部）
		"7700968020511837208", // 学法律的玄学大师 第二季
	}
	for _, seriesID := range series {
		title, chapters, chapErr := d.fetchHongguoChapters(ctx, seriesID)
		if chapErr != nil {
			t.Logf("series=%s 章节失败 %v", seriesID, publicError(chapErr))
			continue
		}
		t.Logf("=== %s（%d 集）", title, len(chapters))
		for i := 0; i < 2 && i < len(chapters); i++ {
			vid := strings.TrimPrefix(chapters[i].VideoURL, "hongguo-cenc://")
			start := time.Now()
			media, mediaErr := d.resolveHongguoMultiMedia(ctx, vid)
			if mediaErr != nil {
				t.Logf("  第%d集 vid=%s FAIL (%v) %v", i+1, vid, time.Since(start).Round(time.Millisecond), publicError(mediaErr))
				continue
			}
			t.Logf("  第%d集 vid=%s OK (%v) dur=%v quality=%d",
				i+1, vid, time.Since(start).Round(time.Millisecond), media.Duration, media.Quality)
		}
	}
}
