//go:build live

package core

import (
	"bytes"
	"io"
	"net/http"
	"sort"
	"strings"
	"testing"
	"time"
)

// 11-07 实机取证：主接口 200 + 空 body 到底是签名失效还是静默限流。
// 生产路径 hongguoBuildMediaCall 构造请求，观察响应头；再用 GET+body 探测
// 服务端是否仍接受签名（历史上会回 400 video platform invalid）。
func TestLiveEmptyBodyForensics20261107(t *testing.T) {
	videoID := "7698761405498936345"
	primary := hongguoDevicePool()[0]
	call := hongguoBuildMediaCall(primary, hongguoPlayHosts[0], videoID)

	for _, method := range []string{http.MethodPost, http.MethodGet} {
		request, err := http.NewRequest(method, call.url, bytes.NewReader(call.body))
		if err != nil {
			t.Fatal(err)
		}
		for name, value := range call.headers {
			request.Header.Set(name, value)
		}
		client := &http.Client{Timeout: 12 * time.Second}
		response, err := client.Do(request)
		if err != nil {
			t.Logf("%s ERR %v", method, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(response.Body, 512))
		response.Body.Close()
		keys := make([]string, 0, len(response.Header))
		for key := range response.Header {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		var head strings.Builder
		for _, key := range keys {
			head.WriteString(key)
			head.WriteString("=")
			head.WriteString(strings.Join(response.Header.Values(key), ","))
			head.WriteString("; ")
		}
		t.Logf("%s HTTP=%d len=%d body=%q", method, response.StatusCode, len(content), string(content))
		t.Logf("  headers: %s", head.String())
		time.Sleep(300 * time.Millisecond)
	}
}
