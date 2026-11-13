//go:build live

package core

import (
	"context"
	"testing"
	"time"
)

// 验证可出流的身份能走完整链路（签名 → fallback_api → spade 解密 → 真实 CDN URL）。
//
//	go test -tags live ./core/ -run TestLiveGoodDevices -v -timeout 240s
func TestLiveGoodDevices(t *testing.T) {
	videoID := "7698761405498936345"
	host := hongguoPlayHosts[0]

	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader

	names := map[string]bool{
		"honor_magic6": true, "oppo_findx7": true,
		"oneplus_12": true, "samsung_s24u": true,
	}
	for _, device := range hongguoDevicePool() {
		if !names[device.Name] {
			continue
		}
		device := device
		t.Run(device.Name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
			defer cancel()
			start := time.Now()
			media, fetchErr := d.hongguoFetchMedia(ctx, videoID, hongguoPlayAttempt{device: device, host: host})
			if fetchErr != nil {
				t.Logf("%-14s FAIL (%v) %v", device.Name, time.Since(start).Round(time.Millisecond), publicError(fetchErr))
				return
			}
			t.Logf("%-14s OK (%v) quality=%d dur=%v codec=%s key=%d",
				device.Name, time.Since(start).Round(time.Millisecond), media.Quality, media.Duration, media.Codec, len(media.CENCKey))
			t.Logf("               url=%.110s", media.URL)
		})
	}
}
