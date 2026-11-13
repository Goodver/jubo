//go:build live

package core

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"testing"
	"time"
)

// 每台设备用「自己的 install_id」做 Cookie + 1.2.21 的播放指纹，逐个实测。
//
//	go test -tags live ./core/ -run TestLivePerDeviceCookie -v -timeout 240s
func TestLivePerDeviceCookie(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()

	playbackUA := "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

	type ident struct {
		name       string
		deviceID   string
		installID  string
		cdid       string
		openudid   string
		deviceTok  string
		ttreq      string
	}
	idents := []ident{
		{"auto", "4016988545905888", "780026313179920", "4d2a63ef-124e-4417-9d48-173157007e2f", "7bbc4f22418b7d81",
			"AAA5DP5KNDSSJVE2ZN2SG7NXNNKRJ4KVQRBD72SAA6LPW5RZOJNKDCJH3MQQN6RQO3J7QOKM5SBZBTHIPOX2MGI4MK2YHQCDADB7B262CRDMDZ7OAMORQZ6D2OAB2",
			"1$67cce80fad505dc0efbe77be309f30c6174f0fe6"},
		{"spare0", "3260526922310188", "3260526922314284", "9eae5c12-6b55-45a0-8d67-ef76452f7a06", "c1e48036f673edff",
			"AAAXB45MKYYIJTVI7XZVZQLLSGEKPZMPBHJ6JW54PDHWNP22DDSOLQFUMXU3UDJWDIM57H7HRBRP3IJW2QKAFBY3KZZBJCLULXUMEDXHVINGGFGYIPILHNCXQ24GA",
			"1$cacda3a3394d9210170d652c93ba610c272a73bf"},
		{"spare1", "428185093163495", "428185093167591", "7726c860-3adf-4cc5-af96-5d1955a23fca", "93f0bc9510036862",
			"AAA2SE5B2ITD7QY53FHVJP2RHDBBWXD6UUZLXNUVQO2YBAZIF2RELPVBAFWV3KLGPR4VYA6H2OVF2FSHDQQCUKUGCIK6UKHXFQ4A",
			"1$435937133d1f3ef8afb99ea8ea686f3d45d3af58"},
		{"spare2", "1905928731624264", "1905928731628360", "729065d8-7d47-4edf-89ed-719409e672f2", "72bb1287b5eebf5e",
			"AAAXT67YNY32QDA2TZZHMG22XCB63YLBQ32TWMMWPQ5DNFOKCZBTJPOKXXTCTNDRXH3USAXDXTJXMMUYJFZGQ37FJB2TQRWQFLCAH3VGK5LNITI3L4UWQ37OXVFRC",
			"1$79d3f6b09bb3bfc5f9bfbe95c5acf8194c559e7c"},
	}

	vid := "7690282289934109720"
	host := hongguoPlayHosts[0]

	for _, id := range idents {
		for _, withTok := range []bool{false, true} {
			dev := hongguoDeviceProfile{
				Name: id.name, Brand: "Redmi", Model: "25053RT47C",
				OSVersion: "16", OSAPI: "36", Resolution: "1280*2772", DPI: "520",
				Channel: "update_64", UserAgent: playbackUA, HostABI: "arm64-v8a",
				DeviceID: id.deviceID, InstallID: id.installID, IID: id.installID,
				CDID: id.cdid, OpenUDID: id.openudid, StoreRegion: "cn", TokenBound: withTok,
			}
			if withTok {
				dev.DeviceToken = id.deviceTok
				dev.TtReq = id.ttreq
			}
			call := hongguoBuildMediaCall(dev, host, vid)
			req, err := http.NewRequestWithContext(ctx, http.MethodPost, call.url, bytes.NewReader(call.body))
			if err != nil {
				t.Fatalf("request: %v", err)
			}
			for k, v := range call.headers {
				req.Header.Set(k, v)
			}
			req.Header.Set("Cookie", "install_id="+id.installID+"; device_id="+id.deviceID)

			start := time.Now()
			resp, err := d.doPlaybackRequest(req, 12*time.Second)
			if err != nil {
				t.Logf("%-8s token=%-5v 网络错误 %v", id.name, withTok, err)
				continue
			}
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
			resp.Body.Close()
			t.Logf("%-8s token=%-5v HTTP=%d len=%d %dms", id.name, withTok, resp.StatusCode, len(body), time.Since(start).Milliseconds())
			if len(body) > 0 {
				t.Logf("   >>> 成功样本: %.200s", string(body))
			}
		}
	}
}
