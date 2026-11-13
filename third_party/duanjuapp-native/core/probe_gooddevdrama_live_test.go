//go:build live

package core

import (
	"context"
	"strings"
	"testing"
	"time"
)

// 用可出流身份验证「手机上失败的剧」也能出流，排除剧集维度的问题。
//
//	go test -tags live ./core/ -run TestLiveGoodDevDrama -v -timeout 240s
func TestLiveGoodDevDrama(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()

	var good hongguoDeviceProfile
	for _, device := range hongguoDevicePool() {
		if device.Name == "honor_magic6" {
			good = device
		}
	}
	host := hongguoPlayHosts[0]

	series := []string{
		"7700968020511837208", // 学法律的玄学大师 第二季
		"7697622096326708286", // 重生八零渔村（app 日志里的 ep1 vid 前缀）
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
			media, mediaErr := d.hongguoFetchMedia(ctx, vid, hongguoPlayAttempt{device: good, host: host})
			if mediaErr != nil {
				t.Logf("  第%d集 vid=%s FAIL %v", i+1, vid, publicError(mediaErr))
				continue
			}
			t.Logf("  第%d集 vid=%s OK dur=%v quality=%d url=%.80s", i+1, vid, media.Duration, media.Quality, media.URL)
		}
	}
}
