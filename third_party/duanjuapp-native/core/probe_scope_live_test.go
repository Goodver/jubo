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

// 判断是「IP 整段被限」还是「仅取流接口被限」，并扫一遍所有线路。
//
//	go test -tags live ./core/ -run TestLiveScope -v -timeout 240s
func TestLiveScope(t *testing.T) {
	videoID := "7698761405498936345"
	device := hongguoDevicePool()[0]

	t.Run("all-hosts", func(t *testing.T) {
		client := &http.Client{Timeout: 12 * time.Second}
		for _, host := range hongguoPlayHosts {
			call := hongguoBuildMediaCall(device, host, videoID)
			req, _ := http.NewRequest(http.MethodPost, call.url, bytes.NewReader(call.body))
			for k, v := range call.headers {
				req.Header.Set(k, v)
			}
			resp, err := client.Do(req)
			if err != nil {
				t.Logf("%-52s ERR %v", host, err)
				continue
			}
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
			resp.Body.Close()
			t.Logf("%-52s HTTP=%d len=%d", host, resp.StatusCode, len(body))
			time.Sleep(300 * time.Millisecond)
		}
	})

	t.Run("search-endpoint", func(t *testing.T) {
		engine, err := newNativeEngine(t.TempDir())
		if err != nil {
			t.Skip(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
		defer cancel()
		entry, searchErr := engine.downloader.searchHongguoDramas(ctx, "霸总")
		if searchErr != nil {
			t.Logf("搜索接口也失败: %v", searchErr)
			return
		}
		t.Logf("搜索接口正常，返回 %d 条 → IP 没被整段封", len(entry.Dramas))
	})
}
