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

// 无签名 + body 变体探测。
// 依据上一实验：带错误签名会被拦成空 body，不带签名反而放行。
//
//	go test -tags live ./core/ -run TestLiveNoSignBody -v -timeout 150s
func TestLiveNoSignBody(t *testing.T) {
	videoID := "7670376722964941848"
	host := "https://api5-normal-lq.fqnovel.com"
	path := "/novel/player/multi_video_model/v1/"

	device := hongguoDevicePool()[0]
	device.DeviceID = "3260526922310188"

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

	bodies := []struct{ name, body string }{
		{"01-项目现有body", `{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["` + videoID + `"]}}`},
		{"02-仅vid映射", `{"mixed_video_id_map":{"1004":["` + videoID + `"]}}`},
		{"03-精简biz_param", `{"biz_param":{"need_all_video_definition":true},"mixed_video_id_map":{"1004":["` + videoID + `"]}}`},
		{"04-video_id字段", `{"video_id":"` + videoID + `"}`},
		{"05-空对象", `{}`},
		{"06-1004数组纯值", `{"mixed_video_id_map":{"1004":["` + videoID + `"]},"biz_param":{}}`},
	}

	for _, b := range bodies {
		body := []byte(b.body)
		rawURL := host + path + "?" + buildQuery()
		req, _ := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
		req.Header.Set("User-Agent", device.UserAgent)
		req.Header.Set("Accept", hongguoAcceptHeader)
		req.Header.Set("Content-Type", hongguoMediaContentType)

		client := &http.Client{Timeout: 15 * time.Second}
		resp, err := client.Do(req)
		if err != nil {
			t.Logf("%-20s ERR %v", b.name, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(resp.Body, 3072))
		resp.Body.Close()
		preview := string(content)
		if len(preview) > 400 {
			preview = preview[:400]
		}
		t.Logf("%-20s HTTP=%d len=%d %s", b.name, resp.StatusCode, len(content), preview)
	}
}
