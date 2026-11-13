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

// 在「exe 真实 URL 结构 + 项目签名」基础上补齐可能缺失的请求头。
// 依据：branch 回算与 exe 一致（=2），说明签名主干可信，差异可能只在附加头。
//
//	go test -tags live ./core/ -run TestLiveHeaderFill -v -timeout 180s
func TestLiveHeaderFill(t *testing.T) {
	videoID := "7670376722964941848"
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

	buildQuery := func() string {
		khronos := time.Now().Unix()
		rticket := time.Now().UnixMilli()
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
		b.WriteString("&ts=" + strconv.FormatInt(khronos, 10))
		return b.String()
	}

	extraSets := []struct {
		name  string
		extra map[string]string
	}{
		{"01-基线", nil},
		{"02-XRequestedWith", map[string]string{"X-Requested-With": "com.phoenix.read"}},
		{"03-storeRegionSrc", map[string]string{"x-tt-store-region-src": "did"}},
		{"04-TraceId", map[string]string{"X-TT-Trace-Id": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}},
		{"05-三者齐上", map[string]string{
			"X-Requested-With":       "com.phoenix.read",
			"x-tt-store-region-src":  "did",
			"X-TT-Trace-Id":          "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
		}},
		{"06-加Cookie区域", map[string]string{
			"X-Requested-With":      "com.phoenix.read",
			"x-tt-store-region-src": "did",
			"Cookie":                "store-region=cn-yn; store-region-src=did",
		}},
		{"07-带odin_tt空", map[string]string{
			"X-Requested-With": "com.phoenix.read",
			"Cookie":           "odin_tt=; store-region=cn-yn",
		}},
	}

	for _, set := range extraSets {
		body := hongguoMediaPayload(videoID)
		khronos := uint32(time.Now().Unix())
		rticket := time.Now().UnixMilli()
		rawURL := host + path + "?" + buildQuery()
		headers := hongguoSignSuite(device, rawURL, body, khronos, uint64(rticket))
		for k, v := range set.extra {
			headers[k] = v
		}

		req, _ := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
		for name, value := range headers {
			req.Header.Set(name, value)
		}
		client := &http.Client{Timeout: 12 * time.Second}
		resp, err := client.Do(req)
		if err != nil {
			t.Logf("%-18s ERR %v", set.name, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		resp.Body.Close()
		mark := ""
		if len(content) > 0 {
			mark = " <<< 有响应"
		}
		t.Logf("%-18s HTTP=%d len=%d%s", set.name, resp.StatusCode, len(content), mark)
		if len(content) > 0 {
			preview := string(content)
			if len(preview) > 300 {
				preview = preview[:300]
			}
			t.Logf("     %s", preview)
		}
		time.Sleep(250 * time.Millisecond)
	}
}
