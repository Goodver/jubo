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

// 依据 exe 内的错误模板「mixed_video_id_map / content_type / data[vid].video_model / JSON」，
// 补上 content_type 字段后重测取流。
//
//	go test -tags live ./core/ -run TestLiveContentType -v -timeout 180s
func TestLiveContentType(t *testing.T) {
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

	bizParam := `"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024}`

	bodies := []struct{ name, body string }{
		{"01-基线(无content_type)", `{` + bizParam + `,"mixed_video_id_map":{"1004":["` + videoID + `"]}}`},
		{"02-content_type=1", `{` + bizParam + `,"content_type":1,"mixed_video_id_map":{"1004":["` + videoID + `"]}}`},
		{"03-content_type=2", `{` + bizParam + `,"content_type":2,"mixed_video_id_map":{"1004":["` + videoID + `"]}}`},
		{"04-content_type=0", `{` + bizParam + `,"content_type":0,"mixed_video_id_map":{"1004":["` + videoID + `"]}}`},
		{"05-content_type字符串", `{` + bizParam + `,"content_type":"video","mixed_video_id_map":{"1004":["` + videoID + `"]}}`},
		{"06-仅map+content_type", `{"content_type":1,"mixed_video_id_map":{"1004":["` + videoID + `"]}}`},
	}

	for _, b := range bodies {
		body := []byte(b.body)
		khronos := uint32(time.Now().Unix())
		rticket := time.Now().UnixMilli()
		rawURL := host + path + "?" + buildQuery()
		headers := hongguoSignSuite(device, rawURL, body, khronos, uint64(rticket))

		req, _ := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
		for name, value := range headers {
			req.Header.Set(name, value)
		}
		client := &http.Client{Timeout: 12 * time.Second}
		resp, err := client.Do(req)
		if err != nil {
			t.Logf("%-22s ERR %v", b.name, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(resp.Body, 1536))
		resp.Body.Close()
		mark := ""
		if len(content) > 0 {
			mark = " <<< 有响应"
		}
		t.Logf("%-22s HTTP=%d len=%d%s", b.name, resp.StatusCode, len(content), mark)
		if len(content) > 0 {
			p := string(content)
			if len(p) > 500 {
				p = p[:500]
			}
			t.Logf("     %s", p)
		}
		time.Sleep(300 * time.Millisecond)
	}
}
