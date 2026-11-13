//go:build live

package core

import (
	"context"
	"testing"
	"time"
)

// 复现手机上「又播不了」的具体错误。
//
//	go test -tags live ./core/ -run TestLiveFailNow -v -timeout 240s
func TestLiveFailNow(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader

	ids := []string{
		"7701639065673681944", // ep1（手机上报失败）
		"7700968020511837208", // ep2（手机上报失败）
		"7698761405498936345", // 文溪归来（之前成功的对照）
	}
	for _, id := range ids {
		id := id
		t.Run(id, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 70*time.Second)
			defer cancel()
			start := time.Now()
			media, resolveErr := d.resolveHongguoMultiMedia(ctx, id)
			elapsed := time.Since(start).Round(time.Millisecond)
			if resolveErr != nil {
				t.Logf("ID=%s FAILED (%v): %v", id, elapsed, resolveErr)
				return
			}
			t.Logf("ID=%s OK (%v) quality=%d dur=%v codec=%s key=%d",
				id, elapsed, media.Quality, media.Duration, media.Codec, len(media.CENCKey))
			t.Logf("    url=%.150s", media.URL)
		})
	}
}
