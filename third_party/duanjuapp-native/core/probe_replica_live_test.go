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
	"strings"
	"testing"
	"time"
)

// 用 http2debug=2 从 exe 抓到的**真实请求头**逐项复刻。
//
// 真实请求（exe 成功取流的那条）长这样：
//
//	:method            GET（带 body）
//	content-length     259
//	cookie             install_id=<iid>
//	x-tt-dt            AAA…（设备票据）
//	x-ss-dp            8662
//	lc                 101
//	passport-sdk-version 5051452
//	x-vc-bdturing-sdk-version 4.0.3.cn
//	x-tt-store-region  cn / x-tt-store-region-src uid
//	accept             application/json; charset=utf-8,application/x-protobuf
//
//	go test -tags live ./core/ -run TestLiveReplica -v -timeout 180s
func TestLiveReplica(t *testing.T) {
	host := "https://api5-normal-lq.fqnovel.com"
	iid := "780026313179920"
	deviceID := "621699152495976"
	deviceToken := "AAASRCFSWTS3QXFLWOI2XZYG345WCLCTTUW6VEQJJGHSYAF3PHLOASXDOQ6LFAAIJHEETKULMSJEU35HZEJV6SBGO3LTRGMN6JX24EX7DAPQJYIJA4OC4OET3BDEY"
	playbackUA := "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
	playbackVersion := "7.1.3.32"

	body := []byte(`{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["7686525480618429465"]}}`)

	cases := []struct {
		name    string
		method  string
		full    bool
		withDT  bool
		postFix bool
	}{
		{"R0-GET-full", http.MethodGet, true, true, false},
		{"R1-GET-core", http.MethodGet, false, true, false},
		{"R2-POST-full", http.MethodPost, true, true, false},
		{"R3-GET-noDT", http.MethodGet, true, false, false},
	}

	for _, c := range cases {
		khronos := uint32(time.Now().Unix())
		ticket := uint64(time.Now().UnixMilli())
		query := hongguoExactQuery(deviceID, iid, khronos, ticket, true)
		rawURL := host + hongguoMultiVideoPath + "?" + query
		random := hongguoRandom32() % 65536
		sum := md5.Sum(body)

		headers := map[string]string{
			"X-Khronos":       fmt.Sprintf("%d", khronos),
			"X-SS-Req-Ticket": fmt.Sprintf("%d", ticket),
			"X-SS-Stub":       strings.ToUpper(hex.EncodeToString(sum[:])),
			"X-Gorgon":        hongguoXGorgon(query, body, khronos, random),
			"X-Helios":        hongguoHelios(khronos),
			"X-Medusa":        hongguoBuildMedusa(rawURL, body, khronos, deviceID, playbackVersion),
			"X-Argus":         base64.StdEncoding.EncodeToString(hongguoLittleEndian32(khronos)),
			"X-Ladon":         base64.StdEncoding.EncodeToString(hongguoBigEndian32(khronos)),
			"Content-Type":    "application/json; charset=utf-8",
			"Cookie":          "install_id=" + iid,
			"User-Agent":      playbackUA,
			"Accept-Encoding": "gzip",
		}
		if c.full {
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
		if c.withDT {
			headers["X-Tt-Dt"] = deviceToken
		}

		request, err := http.NewRequest(c.method, rawURL, bytes.NewReader(body))
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
		content, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		response.Body.Close()
		if strings.EqualFold(response.Header.Get("Content-Encoding"), "gzip") && len(content) > 0 {
			if reader, gzErr := gzip.NewReader(bytes.NewReader(content)); gzErr == nil {
				if plain, _ := io.ReadAll(reader); len(plain) > 0 {
					content = plain
				}
			}
		}
		t.Logf("%-14s status=%d len=%d enc=%s origin=%s",
			c.name, response.StatusCode, len(content),
			response.Header.Get("Content-Encoding"), response.Header.Get("X-Dsa-Origin-Status"))
		if len(content) > 0 {
			head := string(content)
			if len(head) > 400 {
				head = head[:400]
			}
			t.Logf("    body: %s", head)
		}
		time.Sleep(500 * time.Millisecond)
	}
}
