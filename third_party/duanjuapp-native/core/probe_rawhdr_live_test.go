//go:build live

package core

import (
	"bytes"
	"io"
	"net/http"
	"sort"
	"testing"
	"time"
)

// 打印取流接口的完整响应头与状态，寻找限流/风控线索。
//
//	go test -tags live ./core/ -run TestLiveRawHeaders -v -timeout 120s
func TestLiveRawHeaders(t *testing.T) {
	videoID := "7698761405498936345"
	device := hongguoDevicePool()[0]
	host := hongguoPlayHosts[0]
	call := hongguoBuildMediaCall(device, host, videoID)

	t.Logf("POST %s", call.url)
	t.Logf("body=%s", string(call.body))
	keys := make([]string, 0, len(call.headers))
	for k := range call.headers {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		v := call.headers[k]
		if len(v) > 80 {
			v = v[:80] + "..."
		}
		t.Logf("  %s: %s", k, v)
	}

	req, _ := http.NewRequest(http.MethodPost, call.url, bytes.NewReader(call.body))
	for k, v := range call.headers {
		req.Header.Set(k, v)
	}
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("ERR %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	t.Logf("=== 响应 ===")
	t.Logf("HTTP=%d len=%d", resp.StatusCode, len(body))
	hkeys := make([]string, 0, len(resp.Header))
	for k := range resp.Header {
		hkeys = append(hkeys, k)
	}
	sort.Strings(hkeys)
	for _, k := range hkeys {
		t.Logf("  %s: %v", k, resp.Header[k])
	}
	if len(body) > 0 {
		t.Logf("body=%.400s", string(body))
	}
}
