//go:build live

package core

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"testing"
	"time"
)

// 一次性探测：三个播放接口路径 × 多条线路 × 主设备身份，
// 打印状态码与响应体前 400 字节，用来定位 1.2.20 实际使用的接口。
//
//	go test -tags live ./core/ -run TestLiveProbe -v -timeout 120s
func TestLiveProbe(t *testing.T) {
	device := hongguoDevicePool()[0]
	videoID := "7701336636495252504"

	paths := []string{
		"/novel/player/multi_video_model/v1/",
		"/novel/player/video_detail/v1/",
		"/novel/player/multi_video_detail/preload/v1",
	}
	hosts := []string{
		"https://api5-normal-lq.fqnovel.com",
		"https://api5-normal-sinfonlineb.fqnovel.com",
	}

	for _, host := range hosts {
		for _, path := range paths {
			body := hongguoMediaPayload(videoID)
			khronos := uint32(time.Now().Unix())
			ticket := uint64(time.Now().UnixMilli())
			query := hongguoDeviceQuery(device, khronos, ticket)
			rawURL := host + path + "?" + query
			headers := hongguoSignSuite(device, rawURL, body, khronos, ticket)

			req, err := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
			if err != nil {
				t.Logf("%-42s %-52s build err: %v", host, path, err)
				continue
			}
			for name, value := range headers {
				req.Header.Set(name, value)
			}
			client := &http.Client{Timeout: 12 * time.Second}
			resp, err := client.Do(req)
			if err != nil {
				t.Logf("%-42s %-52s ERR %v", host, path, err)
				continue
			}
			content, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			resp.Body.Close()
			preview := string(content)
			if len(preview) > 400 {
				preview = preview[:400] + "..."
			}
			t.Logf("%-42s %-52s HTTP=%d len=%d\n    %s", host, path, resp.StatusCode, len(content), preview)
			fmt.Printf("\n")
		}
	}
}
