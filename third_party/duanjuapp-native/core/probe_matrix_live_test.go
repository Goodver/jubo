//go:build live

package core

import (
	"bytes"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"testing"
	"time"
)

// 正交矩阵：把「与 exe 真实请求的 5 处差异」逐个隔离。
//
//	D0 基线：exe 精确 query（裸 * / ts 末尾）+ 7 头（无 Argus/Ladon）+ TraceId + primary iid
//	D1 基线 + 伪造 X-Argus / X-Ladon（看伪造票据是否致命）
//	D2 基线换成备机 iid（看 iid 与 token 是否必须同源）
//	D3 基线 + Cookie（store-region-src=did; store-region=cn-yn）
//	D4 基线改成 %2A + ts 按字典序（看编码/顺序是否被服务端重算）
//	D5 基线换成 hgonly 老 query 字段集（看字段集本身）
//
//	go test -tags live ./core/ -run TestLiveMatrix -v -timeout 180s
func TestLiveMatrix(t *testing.T) {
	host := "https://api5-normal-lq.fqnovel.com"
	primaryIID := hongguoMediaIID
	spareIID := "428185093167591"
	deviceID := "621699152495976"
	playbackUA := "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
	playbackVersion := "7.1.3.32"

	exactBody := []byte(`{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["7691759547454606361","7677944760518052888","7696831006501768216","7688252128082529342"]}}`)

	cases := []struct {
		name      string
		iid       string
		query     func(kh uint32, tk uint64) string
		extra     map[string]string
		fakeArgu  bool
		withTrace bool
	}{
		{"D0-exact", primaryIID, nil, nil, false, true},
		{"D1-fakeArgusLadon", primaryIID, nil, nil, true, true},
		{"D2-spareIID", spareIID, nil, nil, false, true},
		{"D3-cookie", primaryIID, nil, map[string]string{"Cookie": "store-region-src=did; store-region=cn-yn"}, false, true},
		{"D4-encoded", primaryIID, nil, nil, false, true},
		{"D5-oldQuery", spareIID, nil, nil, false, true},
		{"D6-noTrace", primaryIID, nil, nil, false, false},
	}

	for _, c := range cases {
		khronos := uint32(time.Now().Unix())
		ticket := uint64(time.Now().UnixMilli())

		var query string
		switch c.name {
		case "D5-oldQuery":
			device := hongguoDevicePool()[0]
			device.DeviceID = deviceID
			device.IID = c.iid
			query = hongguoDeviceQuery(device, khronos, ticket)
		case "D4-encoded":
			query = hongguoPlaybackQuery(deviceID, c.iid, khronos, ticket)
		default:
			query = hongguoExactQuery(deviceID, c.iid, khronos, ticket, true)
		}

		rawURL := host + hongguoMultiVideoPath + "?" + query
		random := hongguoRandom32() % 65536
		sum := md5.Sum(exactBody)

		headers := map[string]string{
			"User-Agent":      playbackUA,
			"Content-Type":    hongguoMediaContentType,
			"X-Khronos":       fmt.Sprintf("%d", khronos),
			"X-SS-Req-Ticket": fmt.Sprintf("%d", ticket),
			"X-SS-Stub":       strings.ToUpper(hex.EncodeToString(sum[:])),
			"X-Gorgon":        hongguoXGorgon(query, exactBody, khronos, random),
			"X-Helios":        hongguoHelios(khronos),
			"X-Medusa":        hongguoBuildMedusa(rawURL, exactBody, khronos, deviceID, playbackVersion),
		}
		if c.withTrace {
			headers["X-TT-Trace-Id"] = fmt.Sprintf("00-%08x-%s-01", time.Now().UnixNano()&0xffffffff, hongguoRandomHex(16))
		}
		if c.fakeArgu {
			headers["X-Argus"] = base64.StdEncoding.EncodeToString(hongguoBigEndian32(khronos))
			headers["X-Ladon"] = base64.StdEncoding.EncodeToString(hongguoLittleEndian32(khronos))
		}
		for k, v := range c.extra {
			headers[k] = v
		}

		request, err := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(exactBody))
		if err != nil {
			t.Fatal(err)
		}
		for name, value := range headers {
			request.Header.Set(name, value)
		}
		// 显式固定顺序无关：net/http 按 key 排序发送
		client := &http.Client{Timeout: 15 * time.Second}
		response, err := client.Do(request)
		if err != nil {
			t.Logf("%-18s 请求失败: %v", c.name, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(response.Body, 8192))
		response.Body.Close()
		t.Logf("%-18s status=%d len=%d origin=%s logid=%s",
			c.name, response.StatusCode, len(content),
			response.Header.Get("X-Dsa-Origin-Status"), response.Header.Get("X-Tt-Logid"))
		if len(content) > 0 {
			head := string(content)
			if len(head) > 300 {
				head = head[:300]
			}
			t.Logf("    body: %s", head)
		}
		time.Sleep(400 * time.Millisecond)
	}
}

// hongguoExactQuery 逐字节复刻 exe 的 query：字典序排列、+ → %20、%2A → *，
// 且 ts 追加在末尾（不参与排序）。
func hongguoExactQuery(deviceID, iid string, khronos uint32, ticket uint64, tsLast bool) string {
	pairs := map[string]string{
		"_rticket":              uitoa(ticket),
		"ac":                    "wifi",
		"aid":                   "8662",
		"app_name":              "novelread",
		"channel":               "update_64",
		"device_brand":          "Redmi",
		"device_id":             deviceID,
		"device_platform":       "android",
		"device_type":           "25053RT47C",
		"dpi":                   "520",
		"iid":                   iid,
		"language":              "zh",
		"manifest_version_code": "71332",
		"os":                    "android",
		"os_api":                "36",
		"os_version":            "16",
		"resolution":            "1280*2772",
		"ssmix":                 "a",
		"update_version_code":   "71332",
		"version_code":          "71332",
		"version_name":          "7.1.3.32",
	}
	if !tsLast {
		pairs["ts"] = uitoa(uint64(khronos))
	}
	keys := make([]string, 0, len(pairs))
	for k := range pairs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var builder strings.Builder
	for index, key := range keys {
		if index > 0 {
			builder.WriteByte('&')
		}
		builder.WriteString(hongguoQueryEscape(key))
		builder.WriteByte('=')
		builder.WriteString(hongguoQueryEscape(pairs[key]))
	}
	if tsLast {
		builder.WriteString("&ts=")
		builder.WriteString(uitoa(uint64(khronos)))
	}
	return builder.String()
}
