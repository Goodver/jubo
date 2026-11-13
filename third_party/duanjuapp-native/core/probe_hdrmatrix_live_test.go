//go:build live

package core

import (
	"bytes"
	"io"
	"net/http"
	"testing"
	"time"
)

// 用当前生产参数（精简 query + 注册设备）做签名矩阵对照：
// 判断 200 空 body 是「某个签名头有问题」还是「服务端整体风控」。
//
//	go test -tags live ./core/ -run TestLiveHeaderMatrix -v -timeout 120s
func TestLiveHeaderMatrix(t *testing.T) {
	videoID := "7698761405498936345"
	host := hongguoPlayHosts[0]
	device := hongguoDevicePool()[0]

	type variant struct {
		name  string
		strip []string
	}
	variants := []variant{
		{"01-全套（当前）", nil},
		{"02-去Argus+Ladon", []string{"X-Argus", "X-Ladon"}},
		{"03-去Medusa", []string{"X-Medusa"}},
		{"04-去Helios", []string{"X-Helios"}},
		{"05-去Medusa+Helios", []string{"X-Medusa", "X-Helios"}},
		{"06-去SS-STUB", []string{"X-SS-STUB"}},
		{"07-只留Gorgon+Khronos", []string{"X-Argus", "X-Ladon", "X-Medusa", "X-Helios", "X-SS-STUB", "X-TT-Trace-Id", "X-SS-Req-Ticket"}},
	}

	client := &http.Client{Timeout: 12 * time.Second}
	for _, v := range variants {
		call := hongguoBuildMediaCall(device, host, videoID)
		for _, k := range v.strip {
			delete(call.headers, k)
		}
		req, _ := http.NewRequest(http.MethodPost, call.url, bytes.NewReader(call.body))
		for k, val := range call.headers {
			req.Header.Set(k, val)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Logf("%-26s ERR %v", v.name, err)
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		resp.Body.Close()
		mark := ""
		if len(body) > 0 {
			mark = "  <== 有数据!"
		}
		t.Logf("%-26s HTTP=%d len=%d%s", v.name, resp.StatusCode, len(body), mark)
		time.Sleep(400 * time.Millisecond)
	}
}
