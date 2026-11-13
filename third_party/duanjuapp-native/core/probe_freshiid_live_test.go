//go:build live

package core

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"testing"
	"time"
)

// 播放改用「没被用过的 iid」，验证平台是否按 install_id 维度限制播放。
//
//	go test -tags live ./core/ -run TestLiveFreshIID -v -timeout 240s
func TestLiveFreshIID(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()

	playbackUA := "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
	vid := "7690282289934109720"
	host := hongguoPlayHosts[0]

	base := hongguoDeviceProfile{
		Name: "fresh", Brand: "Redmi", Model: "25053RT47C",
		OSVersion: "16", OSAPI: "36", Resolution: "1280*2772", DPI: "520",
		Channel: "update_64", UserAgent: playbackUA, HostABI: "arm64-v8a",
		StoreRegion: "cn",
	}
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	for i := 0; i < 3; i++ {
		// 15 位、以 78 开头的 install_id 形态（与真实注册号同量级）
		iid := fmt.Sprintf("78%013d", rng.Int63n(1e13))
		did := fmt.Sprintf("3%014d", rng.Int63n(1e14))
		dev := base
		dev.DeviceID = did
		dev.InstallID = iid
		dev.IID = iid
		dev.CDID = hongguoStableUUID(iid)
		dev.OpenUDID = hongguoRandomHex(16)

		call := hongguoBuildMediaCall(dev, host, vid)
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, call.url, bytes.NewReader(call.body))
		for k, v := range call.headers {
			req.Header.Set(k, v)
		}
		req.Header.Set("Cookie", "install_id="+iid)
		resp, err := d.doPlaybackRequest(req, 12*time.Second)
		if err != nil {
			t.Logf("iid=%s 网络错误 %v", iid, err)
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		resp.Body.Close()
		t.Logf("iid=%s HTTP=%d len=%d", iid, resp.StatusCode, len(body))
		if len(body) > 0 {
			t.Logf("  >>> 命中: %.200s", string(body))
		}
	}
}
