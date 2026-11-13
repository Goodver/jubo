//go:build live

package core

import (
	"bytes"
	"io"
	"net/http"
	"testing"
	"time"
)

// 用一个全新的合成身份（不在设备池里）测试，判断额度是否按设备身份计算。
//
//	go test -tags live ./core/ -run TestLiveFreshIdentity -v -timeout 120s
func TestLiveFreshIdentity(t *testing.T) {
	videoID := "7698761405498936345"
	host := hongguoPlayHosts[0]
	client := &http.Client{Timeout: 12 * time.Second}

	// 池外的全新机型 + 全新设备号
	names := []string{"fresh_a", "fresh_b"}
	models := []string{"PGT-AN10", "V2359A"}
	for i, name := range names {
		device := hongguoDeviceProfile{
			Name: name, Brand: "oneplus", Model: models[i],
			OSVersion: "15", OSAPI: "35",
			Resolution: "1264*2780", DPI: "450",
			Channel:    "update_64",
			DeviceID:   hongguoStableDeviceID(name, 1),
			InstallID:  hongguoStableDeviceID(name, 2),
			CDID:       hongguoStableUUID(name),
			OpenUDID:   hongguoStableHex("hg-openudid:"+name, 16),
			StoreRegion: hongguoMediaStoreRegion,
			HostABI:    "arm64-v8a",
		}
		device.IID = device.InstallID
		device.UserAgent = hongguoDeviceAgent("OnePlus", device.OSVersion)

		call := hongguoBuildMediaCall(device, host, videoID)
		req, _ := http.NewRequest(http.MethodPost, call.url, bytes.NewReader(call.body))
		for k, v := range call.headers {
			req.Header.Set(k, v)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Logf("%-8s did=%s ERR %v", name, device.DeviceID, err)
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 256))
		resp.Body.Close()
		tag := ""
		if len(body) > 0 {
			tag = "  <== 全新身份可用!"
		}
		t.Logf("%-8s did=%-20s HTTP=%d len=%d%s", name, device.DeviceID, resp.StatusCode, len(body), tag)
		time.Sleep(400 * time.Millisecond)
	}
}
