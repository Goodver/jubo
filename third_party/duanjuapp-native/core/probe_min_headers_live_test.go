//go:build live

package core

import (
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

// POST 取流的最小必要头探测：从「什么都不带」逐步加到「只差 X-Gorgon」，
// 找出服务端对 POST 的最低要求。
//
//	go test -tags live ./core/ -run TestLiveMinHeaders -v -timeout 180s
func TestLiveMinHeaders(t *testing.T) {
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

	base := func(body []byte) map[string]string {
		sum := md5.Sum(body)
		return map[string]string{
			"User-Agent":   device.UserAgent,
			"Accept":       hongguoAcceptHeader,
			"Content-Type": hongguoMediaContentType,
			"X-SS-STUB":    strings.ToUpper(hex.EncodeToString(sum[:])),
		}
	}

	cases := []struct {
		name string
		mk   func(body []byte, khronos uint32, rticket int64) map[string]string
	}{
		{"01-仅STUB", func(body []byte, k uint32, r int64) map[string]string {
			return base(body)
		}},
		{"02-STUB+Ticket", func(body []byte, k uint32, r int64) map[string]string {
			h := base(body)
			h["X-SS-Req-Ticket"] = strconv.FormatInt(r, 10)
			return h
		}},
		{"03-STUB+Ticket+Khronos", func(body []byte, k uint32, r int64) map[string]string {
			h := base(body)
			h["X-SS-Req-Ticket"] = strconv.FormatInt(r, 10)
			h["X-Khronos"] = strconv.FormatUint(uint64(k), 10)
			return h
		}},
		{"04-再加Helios", func(body []byte, k uint32, r int64) map[string]string {
			h := base(body)
			h["X-SS-Req-Ticket"] = strconv.FormatInt(r, 10)
			h["X-Khronos"] = strconv.FormatUint(uint64(k), 10)
			h["X-Helios"] = hongguoHelios(k)
			return h
		}},
		{"05-STUB+Medusa", func(body []byte, k uint32, r int64) map[string]string {
			h := base(body)
			h["X-SS-Req-Ticket"] = strconv.FormatInt(r, 10)
			h["X-Khronos"] = strconv.FormatUint(uint64(k), 10)
			return h
		}},
	}

	for _, c := range cases {
		body := hongguoMediaPayload(videoID)
		khronos := uint32(time.Now().Unix())
		rticket := time.Now().UnixMilli()
		rawURL := host + path + "?" + buildQuery()
		headers := c.mk(body, khronos, rticket)

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
		content, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		resp.Body.Close()
		mark := ""
		if len(content) > 0 {
			mark = " <<<"
		}
		t.Logf("%-24s HTTP=%d len=%d%s", c.name, resp.StatusCode, len(content), mark)
		if len(content) > 0 {
			p := string(content)
			if len(p) > 300 {
				p = p[:300]
			}
			t.Logf("     %s", p)
		}
		time.Sleep(250 * time.Millisecond)
	}
}
