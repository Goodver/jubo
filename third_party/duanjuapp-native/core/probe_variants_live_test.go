//go:build live

package core

import (
	"bytes"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// 参数变体探测：在精简设备字段基础上逐步叠加标准 App 字段，
// 观察哪种组合能打破「HTTP 200 + 空 body」的风控空响应。
//
//	go test -tags live ./core/ -run TestLiveVariants -v -timeout 150s
func TestLiveVariants(t *testing.T) {
	device := hongguoDevicePool()[0]
	videoID := "7701336636495252504"
	host := "https://api5-normal-lq.fqnovel.com"
	path := "/novel/player/multi_video_model/v1/"

	// 来自 exe 内 is.snssdk settings 模板的标准字段
	standard := [][2]string{
		{"device_platform", "android"},
		{"aid", "8662"},
		{"update_version_code", "73932"},
		{"version_code", "73932"},
		{"app_name", "novelread"},
		{"version_name", "7.3.9.32"},
		{"os", "android"},
		{"ssmix", "a"},
		{"language", "zh"},
		{"manifest_version_code", "73932"},
		{"host_abi", "arm64-v8a"},
		{"dragon_device_type", "phone"},
	}

	variants := []struct {
		name  string
		extra [][2]string
	}{
		{"A-仅精简设备字段", nil},
		{"B-精简+全套标准字段", standard},
		{"C-全套标准字段在前", append([][2]string{}, standard...)},
		{"D-精简+关键三项", [][2]string{{"device_platform", "android"}, {"aid", "8662"}, {"app_name", "novelread"}}},
	}

	for _, v := range variants {
		body := hongguoMediaPayload(videoID)
		khronos := uint32(time.Now().Unix())
		ticket := uint64(time.Now().UnixMilli())

		var q strings.Builder
		if v.name == "C-全套标准字段在前" {
			for _, kv := range v.extra {
				q.WriteString(kv[0] + "=" + hongguoQueryEscape(kv[1]) + "&")
			}
		} else if len(v.extra) > 0 {
			for _, kv := range v.extra {
				q.WriteString(kv[0] + "=" + hongguoQueryEscape(kv[1]) + "&")
			}
		}
		q.WriteString(hongguoDeviceQuery(device, khronos, ticket))

		rawURL := host + path + "?" + q.String()
		headers := hongguoSignSuite(device, rawURL, body, khronos, ticket)

		req, err := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
		if err != nil {
			t.Logf("%-28s build err %v", v.name, err)
			continue
		}
		for name, value := range headers {
			req.Header.Set(name, value)
		}
		client := &http.Client{Timeout: 12 * time.Second}
		resp, err := client.Do(req)
		if err != nil {
			t.Logf("%-28s ERR %v", v.name, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		resp.Body.Close()
		preview := string(content)
		if len(preview) > 260 {
			preview = preview[:260]
		}
		t.Logf("%-28s HTTP=%d len=%d %s", v.name, resp.StatusCode, len(content), preview)
	}
}
