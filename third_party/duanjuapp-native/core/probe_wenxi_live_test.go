//go:build live

package core

import (
	"bytes"
	"io"
	"net/http"
	"testing"
	"time"
)

// 关键实测：修正 keyHash material 后，「文溪归来」这剧（公开通路 404，需走签名取流）
// 是否能用修正后的全套签名拿到 video_model。
//
//	go test -tags live ./core/ -run TestLiveWenxi -v -timeout 120s
func TestLiveWenxi(t *testing.T) {
	videoID := "7698761405498936345"
	host := "https://api5-normal-lq.fqnovel.com"

	device := hongguoDevicePool()[0]
	device.DeviceID = "3260526922310188"
	device.Brand = "Redmi"
	device.Model = "25053RT47C"
	device.OSVersion = "16"
	device.OSAPI = "36"
	device.Resolution = "1280*2772"
	device.DPI = "520"
	device.Channel = "update_64"

	// 用项目真实取流路径生成请求
	call := hongguoBuildMediaCall(device, host, videoID)

	req, _ := http.NewRequest(http.MethodPost, call.url, bytes.NewReader(call.body))
	for name, value := range call.headers {
		req.Header.Set(name, value)
	}
	t.Logf("URL: %s", call.url)

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("ERR %v", err)
	}
	content, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	resp.Body.Close()
	body := string(content)
	t.Logf("HTTP=%d len=%d", resp.StatusCode, len(content))
	t.Logf("BODY: %.600s", body)

	if len(content) == 0 {
		t.Fatal("仍为空响应，签名可能仍有问题")
	}
	if !bytes.Contains(content, []byte("video_model")) {
		t.Logf("未命中 video_model，可能不含播放信息")
	}
}