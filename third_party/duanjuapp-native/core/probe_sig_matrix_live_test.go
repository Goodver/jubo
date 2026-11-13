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

// 对照实验：同一 URL 分别用不同签名组合，观察服务端反应。
// 目的：区分「签名无效」与「参数/其它风控」——两者若表现一致，说明还有别的门槛。
//
//	go test -tags live ./core/ -run TestLiveSigMatrix -v -timeout 120s
func TestLiveSigMatrix(t *testing.T) {
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

	type variant struct {
		name  string
		apply func(map[string]string, hongguoDeviceProfile, string, []byte, uint32, uint64) map[string]string
	}
	variants := []variant{
		{"01-全套签名(当前实现)", func(h map[string]string, d hongguoDeviceProfile, u string, b []byte, k uint32, t uint64) map[string]string {
			return hongguoSignSuite(d, u, b, k, t)
		}},
		{"02-完全无签名", func(h map[string]string, d hongguoDeviceProfile, u string, b []byte, k uint32, t uint64) map[string]string {
			return map[string]string{
				"User-Agent":   d.UserAgent,
				"Content-Type": "application/json; charset=UTF-8",
			}
		}},
		{"03-仅Gorgon+Khronos", func(h map[string]string, d hongguoDeviceProfile, u string, b []byte, k uint32, t uint64) map[string]string {
			q := hongguoRawQuery(u)
			return map[string]string{
				"User-Agent":     d.UserAgent,
				"Content-Type":   "application/json; charset=UTF-8",
				"X-Khronos":      strconv.FormatUint(uint64(k), 10),
				"X-Gorgon":       hongguoXGorgon(q, b, k, hongguoRandom32()%65536),
				"X-SS-Req-Ticket": strconv.FormatUint(t, 10),
			}
		}},
		{"04-全套但去掉Argus/Ladon", func(h map[string]string, d hongguoDeviceProfile, u string, b []byte, k uint32, t uint64) map[string]string {
			full := hongguoSignSuite(d, u, b, k, t)
			delete(full, "X-Argus")
			delete(full, "X-Ladon")
			return full
		}},
	}

	for _, v := range variants {
		body := hongguoMediaPayload(videoID)
		khronos := uint32(time.Now().Unix())
		rticket := time.Now().UnixMilli()
		rawURL := host + path + "?" + buildQuery(int64(khronos), rticket)
		headers := v.apply(nil, device, rawURL, body, khronos, uint64(rticket))

		req, _ := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
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
		if len(preview) > 300 {
			preview = preview[:300]
		}
		t.Logf("%-28s HTTP=%d len=%d %s", v.name, resp.StatusCode, len(content), preview)
	}
}
