//go:build live

package core

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"regexp"
	"testing"
	"time"
)

// 先打一个非播放接口，看服务端有没有下发 Set-Cookie（新的 install_id/odin_tt），
// 再拿这个 iid 去请求播放，验证「播放需要一个刚下发的会话 iid」这个假设。
//
//	go test -tags live ./core/ -run TestLiveSessionCookie -v -timeout 240s
func TestLiveSessionCookie(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()

	playbackUA := "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
	dev := hongguoDeviceProfile{
		Name: "probe", Brand: "Redmi", Model: "25053RT47C",
		OSVersion: "16", OSAPI: "36", Resolution: "1280*2772", DPI: "520",
		Channel: "update_64", UserAgent: playbackUA, HostABI: "arm64-v8a",
		DeviceID: "4016988545905888", InstallID: "780026313179920", IID: "780026313179920",
		CDID: "4d2a63ef-124e-4417-9d48-173157007e2f", OpenUDID: "7bbc4f22418b81",
		StoreRegion: "cn",
	}

	// 1) 章节接口（已知可用）看下发了什么 cookie
	chapterURL := hongguoPlayHosts[0] + "/novel/chapter/get_chapter_list/v1/?series_id=7690197285333912600"
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, chapterURL, nil)
	req.Header.Set("User-Agent", dev.UserAgent)
	resp, err := d.doPlaybackRequest(req, 10*time.Second)
	if err != nil {
		t.Fatalf("章节请求失败: %v", err)
	}
	io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	resp.Body.Close()
	t.Logf("章节 HTTP=%d", resp.StatusCode)
	for k, vs := range resp.Header {
		if k == "Set-Cookie" || k == "set-cookie" {
			for _, v := range vs {
				t.Logf("  Set-Cookie: %s", v)
			}
		}
	}

	// 2) 直接用当前身份请求播放
	vid := "7690282289934109720"
	host := hongguoPlayHosts[0]
	call := hongguoBuildMediaCall(dev, host, vid)
	preq, _ := http.NewRequestWithContext(ctx, http.MethodPost, call.url, bytes.NewReader(call.body))
	for k, v := range call.headers {
		preq.Header.Set(k, v)
	}
	presp, err := d.doPlaybackRequest(preq, 12*time.Second)
	if err != nil {
		t.Fatalf("播放请求失败: %v", err)
	}
	body, _ := io.ReadAll(io.LimitReader(presp.Body, 1<<20))
	presp.Body.Close()
	t.Logf("播放 HTTP=%d len=%d", presp.StatusCode, len(body))
	for k, vs := range presp.Header {
		if regexp.MustCompile(`(?i)^set-cookie$`).MatchString(k) {
			for _, v := range vs {
				t.Logf("  播放 Set-Cookie: %s", v)
			}
		}
	}
	if len(body) > 0 {
		t.Logf("成功样本: %.300s", string(body))
	}
}
