//go:build live

package core

import (
	"bytes"
	"crypto/tls"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

// 协议层对照：强制 HTTP/1.1 vs 默认协商（HTTP/2）。
//
//	go test -tags live ./core/ -run TestLiveProto -v -timeout 120s
func TestLiveProto(t *testing.T) {
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

	clients := []struct {
		name   string
		client *http.Client
	}{
		{"默认(协商h2)", &http.Client{Timeout: 12 * time.Second}},
		{"强制HTTP/1.1", &http.Client{
			Timeout: 12 * time.Second,
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{NextProtos: []string{"http/1.1"}},
				TLSNextProto:    map[string]func(string, *tls.Conn) http.RoundTripper{},
			},
		}},
		{"强制h2仅", &http.Client{
			Timeout: 12 * time.Second,
			Transport: &http.Transport{
				ForceAttemptHTTP2: true,
				TLSClientConfig:   &tls.Config{NextProtos: []string{"h2"}},
			},
		}},
	}

	for _, c := range clients {
		body := hongguoMediaPayload(videoID)
		khronos := uint32(time.Now().Unix())
		rticket := time.Now().UnixMilli()
		rawURL := host + path + "?" + buildQuery(int64(khronos), rticket)
		headers := hongguoSignSuite(device, rawURL, body, khronos, uint64(rticket))

		req, _ := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
		for name, value := range headers {
			req.Header.Set(name, value)
		}
		resp, err := c.client.Do(req)
		if err != nil {
			t.Logf("%-16s ERR %v", c.name, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		resp.Body.Close()
		t.Logf("%-16s HTTP=%d proto=%s len=%d %.200s", c.name, resp.StatusCode, resp.Proto, len(content), string(content))
	}
}
