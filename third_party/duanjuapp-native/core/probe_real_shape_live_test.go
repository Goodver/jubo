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

// 按 exe（HG_DUMP_SIGN=1）实测的真实取流 URL 结构复刻请求。
// 关键：mode=full、参数按字母序、带全套标准 App 字段、iid 为空、不含 device_token/cdid/openudid。
//
//	go test -tags live ./core/ -run TestLiveRealShape -v -timeout 120s
func TestLiveRealShape(t *testing.T) {
	videoID := "7701336636495252504"
	path := "/novel/player/multi_video_model/v1/"

	type profile struct {
		name, host, deviceID, brand, model, osVer, osAPI, res, dpi, channel, vcode, vname string
	}
	cases := []profile{
		{"exe备胎设备(lq)", "https://api5-normal-lq.fqnovel.com", "3260526922310188", "Redmi", "25053RT47C", "16", "36", "1280*2772", "520", "update_64", "71332", "7.1.3.32"},
		{"本机主设备(lq)", "https://api5-normal-lq.fqnovel.com", "4016988545905888", "xiaomi", "23127PN0CC", "14", "34", "1200*2670", "460", "update_64", "71332", "7.1.3.32"},
	}

	// 真实 URL 里 ts 单独排在最后，其余按字母序
	buildQuery := func(p profile, tsSec int64, rticket int64) string {
		pairs := [][2]string{
			{"ac", "wifi"},
			{"aid", "8662"},
			{"app_name", "novelread"},
			{"channel", p.channel},
			{"device_brand", p.brand},
			{"device_id", p.deviceID},
			{"device_platform", "android"},
			{"device_type", p.model},
			{"dpi", p.dpi},
			{"iid", ""},
			{"language", "zh"},
			{"manifest_version_code", p.vcode},
			{"os", "android"},
			{"os_api", p.osAPI},
			{"os_version", p.osVer},
			{"resolution", p.res},
			{"ssmix", "a"},
			{"update_version_code", p.vcode},
			{"version_code", p.vcode},
			{"version_name", p.vname},
		}
		var b strings.Builder
		b.WriteString("_rticket=" + strconv.FormatInt(rticket, 10))
		for _, kv := range pairs {
			b.WriteString("&" + kv[0] + "=" + hongguoQueryEscape(kv[1]))
		}
		b.WriteString("&ts=" + strconv.FormatInt(tsSec, 10))
		return b.String()
	}

	for _, p := range cases {
		device := hongguoDevicePool()[0]
		// 让签名里的设备字段与 URL 保持一致
		device.DeviceID = p.deviceID
		device.Brand = p.brand
		device.Model = p.model
		device.OSVersion = p.osVer
		device.OSAPI = p.osAPI
		device.Resolution = p.res
		device.DPI = p.dpi
		device.Channel = p.channel

		body := hongguoMediaPayload(videoID)
		khronos := uint32(time.Now().Unix())
		rticket := time.Now().UnixMilli()
		rawURL := p.host + path + "?" + buildQuery(p, int64(khronos), rticket)
		headers := hongguoSignSuite(device, rawURL, body, khronos, uint64(rticket))

		req, _ := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
		for name, value := range headers {
			req.Header.Set(name, value)
		}
		client := &http.Client{Timeout: 12 * time.Second}
		resp, err := client.Do(req)
		if err != nil {
			t.Logf("%-22s ERR %v", p.name, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		preview := string(content)
		if len(preview) > 500 {
			preview = preview[:500]
		}
		t.Logf("%-22s HTTP=%d len=%d\n   %s", p.name, resp.StatusCode, len(content), preview)
	}
}
