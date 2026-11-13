//go:build live

package core

import (
	"bytes"
	"compress/gzip"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

// 在 Gorgon/Helios 修正后，用 POST + 不同头部组合，确定最小必需集。
//
//	go test -tags live ./core/ -run TestLivePostMatrix -v -timeout 180s
func TestLivePostMatrix(t *testing.T) {
	host := "https://api5-normal-lq.fqnovel.com"
	iid := "780026313179920"
	deviceID := "621699152495976"
	deviceToken := "AAASRCFSWTS3QXFLWOI2XZYG345WCLCTTUW6VEQJJGHSYAF3PHLOASXDOQ6LFAAIJHEETKULMSJEU35HZEJV6SBGO3LTRGMN6JX24EX7DAPQJYIJA4OC4OET3BDEY"
	playbackUA := "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
	playbackVersion := "7.1.3.32"
	body := []byte(`{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["7686525480618429465"]}}`)

	type variant struct {
		name           string
		extras         bool
		deviceToken    bool
		helios, medusa bool
		argusLadon     bool
	}
	cases := []variant{
		{"P0-full", true, true, true, true, true},
		{"P1-noExtras", false, true, true, true, true},
		{"P2-noDT", true, false, true, true, true},
		{"P3-noHelios", true, true, false, true, true},
		{"P4-noMedusa", true, true, true, false, true},
		{"P5-noArgus", true, true, true, true, false},
		{"P6-onlyGorgon", false, false, false, false, false},
	}

	for _, c := range cases {
		khronos := uint32(time.Now().Unix())
		ticket := uint64(time.Now().UnixMilli())
		query := hongguoExactQuery(deviceID, iid, khronos, ticket, true)
		rawURL := host + hongguoMultiVideoPath + "?" + query
		random := hongguoRandom32() % 65536
		sum := md5.Sum(body)

		headers := map[string]string{
			"Content-Type":    "application/json; charset=utf-8",
			"Cookie":          "install_id=" + iid,
			"User-Agent":      playbackUA,
			"Accept-Encoding": "gzip",
			"X-Khronos":       fmt.Sprintf("%d", khronos),
			"X-SS-Req-Ticket": fmt.Sprintf("%d", ticket),
			"X-SS-Stub":       strings.ToUpper(hex.EncodeToString(sum[:])),
			"X-Gorgon":        hongguoXGorgon(query, body, khronos, random),
		}
		if c.helios {
			headers["X-Helios"] = hongguoHelios(khronos)
		}
		if c.medusa {
			headers["X-Medusa"] = hongguoBuildMedusa(rawURL, body, khronos, deviceID, playbackVersion)
		}
		if c.argusLadon {
			headers["X-Argus"] = base64.StdEncoding.EncodeToString(hongguoLittleEndian32(khronos))
			headers["X-Ladon"] = base64.StdEncoding.EncodeToString(hongguoBigEndian32(khronos))
		}
		if c.extras {
			headers["Accept"] = "application/json; charset=utf-8,application/x-protobuf"
			headers["Lc"] = "101"
			headers["Sdk-Version"] = "2"
			headers["Passport-Sdk-Version"] = "5051452"
			headers["X-VC-BDTuring-SDK-Version"] = "4.0.3.cn"
			headers["X-SS-DP"] = "8662"
			headers["X-Tt-Store-Region"] = "cn"
			headers["X-Tt-Store-Region-Src"] = "uid"
			headers["X-Xs-From-Web"] = "0"
			headers["X-TT-Trace-Id"] = fmt.Sprintf("00-%s-%s-01", hongguoRandomHex(13), hongguoRandomHex(8))
		}
		if c.deviceToken {
			headers["X-Tt-Dt"] = deviceToken
		}

		request, err := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		for name, value := range headers {
			request.Header.Set(name, value)
		}
		client := &http.Client{Timeout: 20 * time.Second}
		response, err := client.Do(request)
		if err != nil {
			t.Logf("%-14s 请求失败: %v", c.name, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(response.Body, 4<<20))
		response.Body.Close()
		if strings.EqualFold(response.Header.Get("Content-Encoding"), "gzip") && len(content) > 0 {
			if reader, gzErr := gzip.NewReader(bytes.NewReader(content)); gzErr == nil {
				if plain, _ := io.ReadAll(reader); len(plain) > 0 {
					content = plain
				}
			}
		}
		verdict := "EMPTY"
		if len(content) > 0 {
			text := string(content)
			if strings.Contains(text, `"code":0`) {
				verdict = "SUCCESS"
			} else if index := strings.Index(text, `"debug_info":"`); index >= 0 {
				verdict = text[index+14 : min(index+90, len(text))]
			}
		}
		t.Logf("%-14s status=%d len=%d %s", c.name, response.StatusCode, len(content), verdict)
		if c.name == "P0-full" && len(content) > 0 {
			os.WriteFile("F:/hongguodesk/media_resp.json", content, 0o644)
		}
		time.Sleep(500 * time.Millisecond)
	}
}
