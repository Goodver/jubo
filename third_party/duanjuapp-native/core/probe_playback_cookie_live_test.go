//go:build live

package core

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// 按 1.2.21 的改动实测：播放请求是否需要「专用设备指纹 + install_id Cookie」。
//
//	go test -tags live ./core/ -run TestLivePlaybackCookie -v -timeout 240s
func TestLivePlaybackCookie(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()

	// 1.2.21 的 playbackSessionIID 里写死的播放专用指纹。
	playbackUA := "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
	playback := hongguoDeviceProfile{
		Name: "playback_1221", Brand: "Redmi", Model: "25053RT47C",
		OSVersion: "16", OSAPI: "36", Resolution: "1280*2772", DPI: "520",
		Channel: "update_64", UserAgent: playbackUA, HostABI: "arm64-v8a",
		DeviceID: "4016988545905888", InstallID: "780026313179920", IID: "780026313179920",
		CDID: "4d2a63ef-124e-4417-9d48-173157007e2f", OpenUDID: "7bbc4f22418b7d81",
		StoreRegion: "cn",
		TokenBound:  false,
	}
	// 沿用老指纹做对照
	legacy := playback
	legacy.Name = "legacy_1220"
	legacy.Brand = "xiaomi"
	legacy.Model = "23127PN0CC"
	legacy.OSVersion = "14"
	legacy.OSAPI = "34"
	legacy.Resolution = "1200*2670"
	legacy.DPI = "460"
	legacy.Channel = "xiaomi_8662_64"
	legacy.UserAgent = hongguoMediaUserAgent
	legacy.StoreRegion = "cn-yn"

	vid := "7690282289934109720" // 异界降临 ep1
	host := hongguoPlayHosts[0]

	type variant struct {
		name   string
		device hongguoDeviceProfile
		cookie string
	}
	cases := []variant{
		{"老指纹/无Cookie", legacy, ""},
		{"新指纹/无Cookie", playback, ""},
		{"新指纹/install_id", playback, "install_id=780026313179920"},
		{"新指纹/install_id+device_id", playback, "install_id=780026313179920; device_id=4016988545905888"},
		{"老指纹/install_id", legacy, "install_id=780026313179920"},
	}

	for _, c := range cases {
		call := hongguoBuildMediaCall(c.device, host, vid)
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, call.url, bytes.NewReader(call.body))
		if err != nil {
			t.Fatalf("request: %v", err)
		}
		for k, v := range call.headers {
			req.Header.Set(k, v)
		}
		if c.cookie != "" {
			req.Header.Set("Cookie", c.cookie)
		}
		start := time.Now()
		resp, err := d.doPlaybackRequest(req, 12*time.Second)
		if err != nil {
			t.Logf("%-26s 网络错误: %v", c.name, err)
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		resp.Body.Close()
		cost := time.Since(start).Milliseconds()
		state := "空"
		if len(body) > 0 {
			state = "有数据"
		}
		hint := ""
		if text := string(body); strings.Contains(text, "video_model") {
			hint = " (含 video_model)"
		}
		t.Logf("%-26s HTTP=%d len=%d %s%s %dms", c.name, resp.StatusCode, len(body), state, hint, cost)
	}
}
