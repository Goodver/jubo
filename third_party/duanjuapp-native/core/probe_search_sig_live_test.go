//go:build live

package core

import (
	"bytes"
	"io"
	"net/http"
	"strconv"
	"testing"
	"time"
)

// 定性实验：搜索接口是否真的校验签名？
// 若「正确签名」与「伪造签名」结果一致，说明服务端不校验，此前「搜索能通=签名正确」
// 的推断不成立，取流失败就仍可能是签名算法本身有误。
//
//	go test -tags live ./core/ -run TestLiveSearchSig -v -timeout 120s
func TestLiveSearchSig(t *testing.T) {
	host := "https://api5-normal-lq.fqnovel.com"
	path := "/reading/bookapi/bookmall/tab/v"

	device := hongguoDevicePool()[0]
	device.DeviceID = "4016988545905888"

	// 参数直接取自 exe HG_DUMP_SIGN 输出（bookmall/tab）
	buildURL := func() string {
		khronos := time.Now().Unix()
		rticket := time.Now().UnixMilli()
		pairs := [][2]string{
			{"ac", "wifi"}, {"aid", "8662"}, {"app_name", "novelread"},
			{"auth_aweme", "true"}, {"auth_backward", "true"}, {"bottom_tab_type", "7"},
			{"cdid", "4d2a63ef-124e-4417-9d48-173157007e2f"},
			{"channel", "xiaomi_8662_64"}, {"client_req_type", "60"},
			{"compliance_status", "0"}, {"device_brand", "xiaomi"},
			{"device_id", "4016988545905888"}, {"device_level", "3"},
			{"device_platform", "android"}, {"device_type", "23127PN0CC"},
			{"disable_digg_stat", "false"}, {"dpi", "460"},
			{"dragon_device_type", "phone"}, {"has_video_cache", "false"},
			{"host_abi", "arm64-v8a"}, {"iid", "780026313179920"},
			{"is_android_pad_screen", "0"}, {"is_horizontal_screen", "false"},
			{"landing_bottom_tab_type", "7"}, {"language", "zh"},
			{"last_tab_index", "0"}, {"last_tab_type", "0"},
			{"manifest_version_code", "73932"}, {"need_personal_recommend", "1"},
			{"offset", "0"}, {"os", "android"}, {"os_api", "34"}, {"os_version", "14"},
			{"player_so_load", "1"}, {"pv_player", "73932"},
			{"req_rank_category_id", "0"}, {"resolution", "1200*2670"},
			{"screen_width_px", "1078"}, {"session_id", ""}, {"ssmix", "a"},
			{"tab_index", "0"}, {"tab_type", "16"},
			{"update_version_code", "73932"}, {"version_code", "73932"},
			{"version_name", "7.3.9.32"},
		}
		var b bytes.Buffer
		b.WriteString("_rticket=" + strconv.FormatInt(rticket, 10))
		for _, kv := range pairs {
			b.WriteString("&" + kv[0] + "=" + hongguoQueryEscape(kv[1]))
		}
		b.WriteString("&ts=" + strconv.FormatInt(khronos, 10))
		return host + path + "?" + b.String()
	}

	cases := []struct {
		name  string
		sign  bool
		tamper bool
	}{
		{"正确签名", true, false},
		{"伪造签名", true, true},
		{"无任何签名", false, false},
	}

	for _, c := range cases {
		rawURL := buildURL()
		khronos := uint32(time.Now().Unix())
		req, _ := http.NewRequest(http.MethodGet, rawURL, nil)
		req.Header.Set("User-Agent", device.UserAgent)
		req.Header.Set("Accept", hongguoAcceptHeader)
		if c.sign {
			for name, value := range hongguoSignSuite(device, rawURL, nil, khronos, uint64(time.Now().UnixMilli())) {
				req.Header.Set(name, value)
			}
			if c.tamper {
				req.Header.Set("X-Gorgon", "0404b0d3ffffffffffffffffffffffffffffffff")
				req.Header.Set("X-Khronos", "1")
			}
		}
		client := &http.Client{Timeout: 15 * time.Second}
		resp, err := client.Do(req)
		if err != nil {
			t.Logf("%-12s ERR %v", c.name, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		preview := string(content)
		if len(preview) > 200 {
			preview = preview[:200]
		}
		t.Logf("%-12s HTTP=%d len=%d %s", c.name, resp.StatusCode, len(content), preview)
	}
}
