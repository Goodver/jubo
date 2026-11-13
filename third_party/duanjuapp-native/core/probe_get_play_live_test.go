//go:build live

package core

import (
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

// GET 取流探测：POST 必须带正确签名，但 GET 在无签名下可放行（搜索已验证）。
// 尝试用 GET 走各播放接口，看是否存在免签名路径。
//
//	go test -tags live ./core/ -run TestLiveGetPlay -v -timeout 150s
func TestLiveGetPlay(t *testing.T) {
	videoID := "7693569481984969752"
	seriesID := "7695672348837432344"
	host := "https://api5-normal-lq.fqnovel.com"

	device := hongguoDevicePool()[0]

	base := func() string {
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

	probes := []struct{ name, path, extra string }{
		{"A-detail带video_id", "/novel/player/video_detail/v1/", "video_id=" + videoID + "&"},
		{"B-detail带vid", "/novel/player/video_detail/v1/", "vid=" + videoID + "&"},
		{"C-multi带video_id", "/novel/player/multi_video_model/v1/", "video_id=" + videoID + "&"},
		{"D-preload带vid", "/novel/player/multi_video_detail/preload/v1", "vid=" + videoID + "&"},
		{"E-带剧集双参", "/novel/player/video_detail/v1/", "series_id=" + seriesID + "&video_id=" + videoID + "&"},
	}

	for _, p := range probes {
		rawURL := host + p.path + p.extra + base()
		req, _ := http.NewRequest(http.MethodGet, rawURL, nil)
		req.Header.Set("User-Agent", device.UserAgent)
		req.Header.Set("Accept", hongguoAcceptHeader)

		client := &http.Client{Timeout: 12 * time.Second}
		resp, err := client.Do(req)
		if err != nil {
			t.Logf("%-18s ERR %v", p.name, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(resp.Body, 3072))
		resp.Body.Close()
		preview := string(content)
		if len(preview) > 320 {
			preview = preview[:320]
		}
		t.Logf("%-18s HTTP=%d len=%d %s", p.name, resp.StatusCode, len(content), preview)
	}
}
