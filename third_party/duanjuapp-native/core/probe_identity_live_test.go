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

// 对比不同设备身份对同一 videoID 的取流结果，判断是「身份被拉黑」还是「签名整体失效」。
//
//	go test -tags live ./core/ -run TestLiveIdentity -v -timeout 180s
func TestLiveIdentity(t *testing.T) {
	videoID := "7698761405498936345" // 文溪归来：17:55 用 exe 身份成功过

	cases := []struct {
		name   string
		mutate func(p *hongguoDeviceProfile)
	}{
		{
			name: "exe-3260526922310188",
			mutate: func(p *hongguoDeviceProfile) {
				p.DeviceID = "3260526922310188"
				p.Brand = "Redmi"
				p.Model = "25053RT47C"
				p.OSVersion = "16"
				p.OSAPI = "36"
				p.Resolution = "1280*2772"
				p.DPI = "520"
				p.Channel = "update_64"
			},
		},
		{name: "pool0-default", mutate: func(p *hongguoDeviceProfile) {}},
	}

	pool := hongguoDevicePool()
	t.Logf("设备池大小=%d", len(pool))
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			device := pool[0]
			c.mutate(&device)
			host := hongguoPlayHosts[0]
			call := hongguoBuildMediaCall(device, host, videoID)
			req, _ := http.NewRequest(http.MethodPost, call.url, bytes.NewReader(call.body))
			for k, v := range call.headers {
				req.Header.Set(k, v)
			}
			client := &http.Client{Timeout: 15 * time.Second}
			resp, err := client.Do(req)
			if err != nil {
				t.Logf("device_id=%s ERR %v", device.DeviceID, err)
				return
			}
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
			resp.Body.Close()
			t.Logf("device_id=%s host=%s HTTP=%d len=%d", device.DeviceID, host, resp.StatusCode, len(body))
			if len(body) > 0 {
				t.Logf("    body=%.200s", string(body))
			}
		})
	}

	// 再串行跑一次下载器完整路径，看是否与裸请求一致
	t.Run("full-path", func(t *testing.T) {
		engine, err := newNativeEngine(t.TempDir())
		if err != nil {
			t.Skip(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
		media, resolveErr := engine.downloader.resolveHongguoMultiMedia(ctx, videoID)
		if resolveErr != nil {
			t.Logf("full-path FAILED: %v", resolveErr)
			return
		}
		t.Logf("full-path OK quality=%d", media.Quality)
	})
}
