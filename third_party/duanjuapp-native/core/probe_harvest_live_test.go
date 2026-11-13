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

// 打详情接口（已知可用），看服务端是否下发 Set-Cookie 里的 install_id ——
// 如果下发，说明 1.2.21 的 iid 池就是从这类响应里攒出来的。
//
//	go test -tags live ./core/ -run TestLiveCookieHarvest -v -timeout 120s
func TestLiveCookieHarvest(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	dev := hongguoDevicePool()[0]
	host := hongguoPlayHosts[0]
	body := []byte(`{"series_id":"7690197285333912600"}`)
	path := "/novel/player/video_detail/v1/"

	khronos := uint32(time.Now().Unix())
	ticket := uint64(time.Now().UnixMilli())
	query := hongguoDeviceQuery(dev, khronos, ticket)
	rawURL := strings.TrimRight(host, "/") + path + "?" + query
	headers := hongguoSignSuite(dev, rawURL, body, khronos, ticket)

	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, rawURL, bytes.NewReader(body))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := d.doPlaybackRequest(req, 12*time.Second)
	if err != nil {
		t.Fatalf("请求失败: %v", err)
	}
	payload, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	resp.Body.Close()
	t.Logf("HTTP=%d len=%d", resp.StatusCode, len(payload))
	for k, vs := range resp.Header {
		for _, v := range vs {
			t.Logf("  %s: %s", k, v)
		}
	}
}
