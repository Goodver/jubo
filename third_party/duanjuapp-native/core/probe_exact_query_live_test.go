//go:build live

package core

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"testing"
	"time"
)

// 依据 HG_DUMP_SIGN 抓到的 exe 真实播放请求，原样复刻 query 字段集。
//
// 实测 exe 发出的 multi_video_model 请求（mode=full）字段为：
//
//	_rticket ac aid app_name channel device_brand device_id device_platform
//	device_type dpi iid language manifest_version_code os os_api os_version
//	resolution ssmix update_version_code version_code version_name ts
//
// 其中设备参数固定是「播放指纹」（Redmi / 25053RT47C / os 16 / 1280*2772 / dpi 520），
// device_id 取当前身份，iid 从别的身份借（borrowIID 语义）。
//
// 当前工程发的却是 install_id / cdid / openudid / user_agent / odin_tt /
// device_token / ttreq / store_region —— 与 exe 的字段集几乎不重叠。
//
//	go test -tags live ./core/ -run TestLiveExactQuery -v -timeout 180s
func TestLiveExactQuery(t *testing.T) {
	videoID := "7698761405498936345"
	host := "https://api5-normal-lq.fqnovel.com"

	raw, err := os.ReadFile("testdata/identities.json")
	if err != nil {
		t.Fatalf("读不到身份表: %v", err)
	}
	var identities []hongguoIdentityFixture
	if err := json.Unmarshal(raw, &identities); err != nil {
		t.Fatalf("身份表解析失败: %v", err)
	}

	// 日志里 device_id=621699152495976 是 spare5
	deviceID := identities[6].DeviceID
	// 日志里这个 device_id 依次借用了 auto / spare1 的 iid
	borrowed := []string{identities[0].InstallID, identities[2].InstallID, identities[1].InstallID}

	// 播放会话写死的指纹（playbackSessionIID）
	const (
		playbackUA      = "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
		playbackVersion = "7.1.3.32"
	)
	device := hongguoDevicePool()[0]
	device.DeviceID = deviceID
	device.Brand = "Redmi"
	device.Model = "25053RT47C"
	device.OSVersion = "16"
	device.OSAPI = "36"
	device.Resolution = "1280*2772"
	device.DPI = "520"
	device.Channel = "update_64"
	device.UserAgent = playbackUA

	client := &http.Client{Timeout: 15 * time.Second}
	for index, iid := range borrowed {
		khronos := uint32(time.Now().Unix())
		ticket := uint64(time.Now().UnixMilli())
		query := hongguoPlaybackQuery(deviceID, iid, khronos, ticket)
		rawURL := host + hongguoMultiVideoPath + "?" + query
		body := hongguoMediaPayload(videoID)

		headers := hongguoSignSuite(device, rawURL, body, khronos, ticket)
		headers["X-Medusa"] = hongguoBuildMedusa(rawURL, body, khronos, deviceID, playbackVersion)

		request, err := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
		if err != nil {
			t.Fatalf("构造失败: %v", err)
		}
		for name, value := range headers {
			request.Header.Set(name, value)
		}
		response, err := client.Do(request)
		if err != nil {
			t.Logf("#%d iid=%s 请求失败: %v", index, iid, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(response.Body, 8192))
		response.Body.Close()
		note := ""
		if bytes.Contains(content, []byte("video_model")) {
			note = "  <<== 命中 video_model"
		}
		head := string(content)
		if len(head) > 160 {
			head = head[:160]
		}
		t.Logf("#%d iid=%-17s HTTP=%d len=%-5d%s %s", index, iid, response.StatusCode, len(content), note, head)
		if len(content) > 0 {
			t.Logf("完整 URL: %s", rawURL)
			break
		}
	}
}

// hongguoPlaybackQuery 复刻 exe 播放请求的 query（字段与顺序取自 HG_DUMP_SIGN 抓包）。
// 用 url.Values 是为了让它按字母序编码，与 exe 的输出一致。
func hongguoPlaybackQuery(deviceID, iid string, khronos uint32, ticket uint64) string {
	values := url.Values{}
	values.Set("_rticket", uitoa(ticket))
	values.Set("ac", "wifi")
	values.Set("aid", "8662")
	values.Set("app_name", "novelread")
	values.Set("channel", "update_64")
	values.Set("device_brand", "Redmi")
	values.Set("device_id", deviceID)
	values.Set("device_platform", "android")
	values.Set("device_type", "25053RT47C")
	values.Set("dpi", "520")
	values.Set("iid", iid)
	values.Set("language", "zh")
	values.Set("manifest_version_code", "71332")
	values.Set("os", "android")
	values.Set("os_api", "36")
	values.Set("os_version", "16")
	values.Set("resolution", "1280*2772")
	values.Set("ssmix", "a")
	values.Set("update_version_code", "71332")
	values.Set("version_code", "71332")
	values.Set("version_name", "7.1.3.32")
	values.Set("ts", uitoa(uint64(khronos)))
	return values.Encode()
}

func uitoa(value uint64) string {
	if value == 0 {
		return "0"
	}
	buffer := [20]byte{}
	pos := len(buffer)
	for value > 0 {
		pos--
		buffer[pos] = byte('0' + value%10)
		value /= 10
	}
	return string(buffer[pos:])
}
