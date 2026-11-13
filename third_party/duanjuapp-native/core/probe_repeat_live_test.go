//go:build live

package core

import (
	"bytes"
	"io"
	"net/http"
	"testing"
	"time"
)

// 同一身份连打 N 次，判断拒绝是「随机/概率」还是「状态性全灭」。
//
//	go test -tags live ./core/ -run TestLiveRepeat -v -timeout 180s
func TestLiveRepeat(t *testing.T) {
	videoID := "7698761405498936345"
	host := hongguoPlayHosts[0]
	client := &http.Client{Timeout: 12 * time.Second}

	targets := []string{"honor_magic6", "xiaomi_14"}
	for _, name := range targets {
		var device hongguoDeviceProfile
		for _, candidate := range hongguoDevicePool() {
			if candidate.Name == name {
				device = candidate
			}
		}
		ok, empty := 0, 0
		for i := 0; i < 8; i++ {
			call := hongguoBuildMediaCall(device, host, videoID)
			req, _ := http.NewRequest(http.MethodPost, call.url, bytes.NewReader(call.body))
			for k, v := range call.headers {
				req.Header.Set(k, v)
			}
			resp, err := client.Do(req)
			if err != nil {
				t.Logf("%-12s #%d ERR %v", name, i+1, err)
				continue
			}
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 128))
			resp.Body.Close()
			if len(body) > 0 {
				ok++
			} else {
				empty++
			}
			time.Sleep(600 * time.Millisecond)
		}
		t.Logf("%-12s 8 次：有数据=%d 空=%d", name, ok, empty)
	}
}
