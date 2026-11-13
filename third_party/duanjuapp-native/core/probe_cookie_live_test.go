//go:build live

package core

import (
	"bytes"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Cookie 变体探测：exe 内部有 loginCookies 结构，且 device.json 记录了 store_region=cn-yn。
// 这里验证取流接口是否要求特定 Cookie。
//
//	go test -tags live ./core/ -run TestLiveCookie -v -timeout 120s
func TestLiveCookie(t *testing.T) {
	videoID := "7693569481984969752"
	host := "https://api5-normal-lq.fqnovel.com"
	path := "/novel/player/multi_video_model/v1/"

	device := hongguoDevicePool()[0]
	device.DeviceID = "3260526922310188"
	device.Brand = "Redmi"
	device.Model = "25053RT47C"
	device.OSVersion = "16"
	device.OSAPI = "36"
	device.Resolution = "1280*2772"
	device.DPI = "520"
	device.Channel = "update_64"

	buildQuery := func(tsSec, rticket int64) string {
		pairs := [][2]string{
			{"ac", "wifi"}, {"aid", "8662"}, {"app_name", "novelread"},
			{"channel", "update_64"}, {"device_brand", "Redmi"},
			{"device_id", "3260526922310188"}, {"device_platform", "android"},
			{"device_type", "25053RT47C"}, {"dpi", "520"}, {"iid", ""},
			{"language", "zh"}, {"manifest_version_code", "71332"},
			{"os", "android"}, {"os_api", "36"}, {"os_version", "16"},
			{"resolution", "1280*2772"}, {"ssmix", "a"},
			{"update_version_code", "71332"}, {"version_code", "71332"},
			{"version_name", "7.1.3.32"},
		}
		var b strings.Builder
		b.WriteString("_rticket=" + strconv.FormatInt(rticket, 10))
		for _, kv := range pairs {
			b.WriteString("&" + kv[0] + "=" + hongguoQueryEscape(kv[1]))
		}
		b.WriteString("&ts=" + strconv.FormatInt(tsSec, 10))
		return b.String()
	}

	cookies := []struct{ name, value string }{
		{"00-无Cookie", ""},
		{"01-store-region", "store-region=cn-yn"},
		{"02-store-region-src", "store-region=cn-yn; store-region-src=did"},
		{"03-带设备标识", "store-region=cn-yn; store-region-src=did; device_id=3260526922310188; install_id=3260526922314284"},
		{"04-带ttwid空", "store-region=cn-yn; ttwid=; odin_tt="},
	}

	for _, c := range cookies {
		body := hongguoMediaPayload(videoID)
		khronos := uint32(time.Now().Unix())
		rticket := time.Now().UnixMilli()
		rawURL := host + path + "?" + buildQuery(int64(khronos), rticket)
		headers := hongguoSignSuite(device, rawURL, body, khronos, uint64(rticket))
		if c.value != "" {
			headers["Cookie"] = c.value
		}

		req, _ := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
		for name, value := range headers {
			req.Header.Set(name, value)
		}
		client := &http.Client{Timeout: 12 * time.Second}
		resp, err := client.Do(req)
		if err != nil {
			t.Logf("%-24s ERR %v", c.name, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		resp.Body.Close()
		preview := string(content)
		if len(preview) > 300 {
			preview = preview[:300]
		}
		t.Logf("%-24s HTTP=%d len=%d %s", c.name, resp.StatusCode, len(content), preview)
	}
}
