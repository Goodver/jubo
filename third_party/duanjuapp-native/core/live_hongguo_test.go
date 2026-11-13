//go:build live

package core

import (
	"context"
	"strings"
	"testing"
	"time"
)

// 联调冒烟测试（默认不跑，需显式开启）：
//
//	go test -tags live ./core/ -run TestLiveHongguo -v -timeout 180s
func TestLiveHongguoPlayback(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	entry, err := d.searchHongguoDramas(ctx, "霸总")
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	t.Logf("搜索结果 %d 条", len(entry.Dramas))
	if len(entry.Dramas) == 0 {
		t.Fatal("no dramas")
	}
	_, seriesID, ok := splitProviderDramaID(entry.Dramas[0].ID)
	if !ok {
		t.Fatalf("bad id %q", entry.Dramas[0].ID)
	}
	t.Logf("剧：%s  series=%s", entry.Dramas[0].Title, seriesID)

	title, chapters, err := d.fetchHongguoChapters(ctx, seriesID)
	if err != nil {
		t.Fatalf("chapters: %v", err)
	}
	t.Logf("剧名 %s，%d 集", title, len(chapters))
	if len(chapters) == 0 {
		t.Fatal("no chapters")
	}
	videoID := strings.TrimPrefix(chapters[0].VideoURL, "hongguo-cenc://")
	t.Logf("首集 vid=%s", videoID)

	start := time.Now()
	media, err := d.resolveHongguoMultiMedia(ctx, videoID)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	t.Logf("耗时 %v", time.Since(start).Round(time.Millisecond))
	t.Logf("URL=%s", truncate(media.URL, 120))
	t.Logf("quality=%d codec=%s key=%d bytes variants=%d",
		media.Quality, media.Codec, len(media.CENCKey), len(media.Variants))
	if !isProviderHTTPMediaURL(media.URL) {
		t.Fatalf("bad url")
	}
}
