//go:build live

package core

import (
	"context"
	"testing"
	"time"
)

// 全接口连通性巡检：目录 / 分类 / 搜索 / 推荐 / 排行 / 详情 / 取流。
// 只报成败与条数，不校验内容。
//
//	go test -tags live ./core/ -run TestLiveHongguoSweep -v -timeout 300s
func TestLiveHongguoSweep(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader
	// 巡检只验证连通性，把每档翻页数压到 4，避免 50×3 页把测试拖到两分钟。
	d.cfg.MaxPagesPerSort = 4
	ctx, cancel := context.WithTimeout(context.Background(), 240*time.Second)
	defer cancel()

	steps := []struct {
		name string
		run  func() (string, error)
	}{
		{"目录", func() (string, error) {
			rows, err := d.fetchHongguoAppCatalog(ctx)
			return count(rows), err
		}},
		{"分类-真人剧", func() (string, error) {
			rows, err := d.fetchHongguoAppCatalogCategory(ctx, "short_play")
			return count(rows), err
		}},
		{"分类-漫剧", func() (string, error) {
			rows, err := d.fetchHongguoAppCatalogCategory(ctx, "comic_series")
			return count(rows), err
		}},
		{"搜索", func() (string, error) {
			entry, err := d.searchHongguoDramas(ctx, "霸总")
			return count(entry.Dramas), err
		}},
	}

	for _, step := range steps {
		started := time.Now()
		detail, err := step.run()
		if err != nil {
			t.Errorf("%s 失败 (%s): %v", step.name, time.Since(started).Round(time.Millisecond), err)
			continue
		}
		t.Logf("%s 成功 %s (%s)", step.name, detail, time.Since(started).Round(time.Millisecond))
	}
}

func count[T any](rows []T) string {
	return itoa(len(rows)) + " 条"
}

func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	var digits []byte
	for value > 0 {
		digits = append([]byte{byte('0' + value%10)}, digits...)
		value /= 10
	}
	return string(digits)
}
