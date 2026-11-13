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

// 用 1.2.21 的新指纹（Redmi 25053RT47C / Android 16 / UA 71332 / update_64）
// 打详情和播放两个接口，验证「平台只放行新版 App 指纹」这个假设。
//
//	go test -tags live ./core/ -run TestLiveNewFingerprint -v -timeout 180s
func TestLiveNewFingerprint(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()

	newUA := "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

	type profile struct {
		name   string
		device hongguoDeviceProfile
	}
	base := hongguoDevicePool()[0]
	fresh := base
	fresh.Name = "new_fp"
	fresh.Brand = "Redmi"
	fresh.Model = "25053RT47C"
	fresh.OSVersion = "16"
	fresh.OSAPI = "36"
	fresh.Resolution = "1280*2772"
	fresh.DPI = "520"
	fresh.Channel = "update_64"
	fresh.UserAgent = newUA
	fresh.HostABI = "arm64-v8a"
	fresh.StoreRegion = "cn"

	host := hongguoPlayHosts[0]
	mix := fresh
	mix.Name = "混合iid"
	mix.DeviceID = "4016988545905888"
	mix.InstallID = "780026313179920"
	mix.IID = "1905928731628360"
	mix.CDID = "4d2a63ef-124e-4417-9d48-173157007e2f"
	mix.OpenUDID = "7bbc4f22418b7d81"

	for _, p := range []profile{{"老指纹/1.2.20", base}, {"新指纹/1.2.21", fresh}, {"混合iid", mix}} {
		// 详情
		body := []byte(`{"series_id":"7690197285333912600"}`)
		khronos := uint32(time.Now().Unix())
		ticket := uint64(time.Now().UnixMilli())
		rawURL := strings.TrimRight(host, "/") + "/novel/player/video_detail/v1/?" + hongguoDeviceQuery(p.device, khronos, ticket)
		headers := hongguoSignSuite(p.device, rawURL, body, khronos, ticket)
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, rawURL, bytes.NewReader(body))
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		resp, err := d.doPlaybackRequest(req, 12*time.Second)
		if err != nil {
			t.Logf("%-16s 详情 网络错误 %v", p.name, err)
		} else {
			payload, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
			resp.Body.Close()
			t.Logf("%-16s 详情 HTTP=%d len=%d", p.name, resp.StatusCode, len(payload))
			if len(payload) > 0 {
				t.Logf("   >>> 详情样本: %.160s", string(payload))
			}
		}

		// 播放
		call := hongguoBuildMediaCall(p.device, host, "7690282289934109720")
		preq, _ := http.NewRequestWithContext(ctx, http.MethodPost, call.url, bytes.NewReader(call.body))
		for k, v := range call.headers {
			preq.Header.Set(k, v)
		}
		if p.name == "混合iid" {
			preq.Header.Set("Cookie", "install_id=1905928731628360")
		}
		presp, err := d.doPlaybackRequest(preq, 12*time.Second)
		if err != nil {
			t.Logf("%-16s 播放 网络错误 %v", p.name, err)
			continue
		}
		pbody, _ := io.ReadAll(io.LimitReader(presp.Body, 1<<20))
		presp.Body.Close()
		t.Logf("%-16s 播放 HTTP=%d len=%d", p.name, presp.StatusCode, len(pbody))
		if len(pbody) > 0 {
			t.Logf("   >>> 播放样本: %.200s", string(pbody))
		}
	}
}
