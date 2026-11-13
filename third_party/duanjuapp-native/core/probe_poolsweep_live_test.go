//go:build live

package core

import (
	"bytes"
	"io"
	"net/http"
	"testing"
	"time"
)

// 遍历设备池里每一个身份，看是否有能取到流的（判断是否卡在 device_token 上）。
//
//	go test -tags live ./core/ -run TestLivePoolSweep -v -timeout 180s
func TestLivePoolSweep(t *testing.T) {
	videoID := "7698761405498936345"
	host := hongguoPlayHosts[0]
	client := &http.Client{Timeout: 12 * time.Second}

	for _, device := range hongguoDevicePool() {
		call := hongguoBuildMediaCall(device, host, videoID)
		req, _ := http.NewRequest(http.MethodPost, call.url, bytes.NewReader(call.body))
		for k, v := range call.headers {
			req.Header.Set(k, v)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Logf("%-16s did=%-20s ERR %v", device.Name, device.DeviceID, err)
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 256))
		resp.Body.Close()
		tag := ""
		if len(body) > 0 {
			tag = "  <== 有数据!"
		}
		t.Logf("%-16s did=%-20s token=%-5v HTTP=%d len=%d%s",
			device.Name, device.DeviceID, device.TokenBound, resp.StatusCode, len(body), tag)
		time.Sleep(350 * time.Millisecond)
	}
}
