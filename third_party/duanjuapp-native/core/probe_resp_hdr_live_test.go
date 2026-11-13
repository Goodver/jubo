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

// 打印完整响应头，判断 200 空包到底是「签名被拒」还是「参数被拒」。
//
//	go test -tags live ./core/ -run TestLiveRespHeaders -v -timeout 180s
func TestLiveRespHeaders(t *testing.T) {
	videoID := "7698761405498936345"
	host := "https://api5-normal-lq.fqnovel.com"
	deviceID := "621699152495976"
	iid := "780026313179920"
	playbackUA := "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
	playbackVersion := "7.1.3.32"

	client := &http.Client{Timeout: 15 * time.Second}

	cases := []struct {
		label string
		want  func(base map[string]string, query string, body []byte, kh uint32, rnd uint32)
	}{
		{"A-九头全套(含Argus/Ladon/TraceID)", func(h map[string]string, q string, b []byte, kh uint32, rnd uint32) {
			h["X-Argus"] = base64.StdEncoding.EncodeToString(hongguoBigEndian32(kh))
			h["X-Ladon"] = base64.StdEncoding.EncodeToString(hongguoLittleEndian32(kh))
			h["X-TT-Trace-Id"] = "00-8f3a1c2d4e5b6a70-9c0d1e2f3a4b5c60-01"
		}},
		{"B-去掉Medusa", func(h map[string]string, q string, b []byte, kh uint32, rnd uint32) {
			delete(h, "X-Medusa")
			h["X-TT-Trace-Id"] = "00-8f3a1c2d4e5b6a70-9c0d1e2f3a4b5c60-01"
		}},
		{"C-去掉Gorgon", func(h map[string]string, q string, b []byte, kh uint32, rnd uint32) {
			delete(h, "X-Gorgon")
			h["X-TT-Trace-Id"] = "00-8f3a1c2d4e5b6a70-9c0d1e2f3a4b5c60-01"
		}},
	}

	for _, item := range cases {
		khronos := uint32(time.Now().Unix())
		ticket := uint64(time.Now().UnixMilli())
		query := hongguoPlaybackQuery(deviceID, iid, khronos, ticket)
		rawURL := host + hongguoMultiVideoPath + "?" + query
		body := hongguoMediaPayload(videoID)
		random := hongguoRandom32() % 65536
		sum := md5.Sum(body)
		headers := map[string]string{
			"User-Agent":      playbackUA,
			"Content-Type":    hongguoMediaContentType,
			"X-Khronos":       fmt.Sprintf("%d", khronos),
			"X-SS-Req-Ticket": fmt.Sprintf("%d", ticket),
			"X-SS-Stub":       strings.ToUpper(hex.EncodeToString(sum[:])),
			"X-Gorgon":        hongguoXGorgon(query, body, khronos, random),
			"X-Helios":        hongguoHelios(khronos),
			"X-Medusa":        hongguoBuildMedusa(rawURL, body, khronos, deviceID, playbackVersion),
		}
		item.want(headers, query, body, khronos, random)

		request, err := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
		if err != nil {
			t.Fatalf("%s 构造失败: %v", item.label, err)
		}
		for name, value := range headers {
			request.Header.Set(name, value)
		}
		response, err := client.Do(request)
		if err != nil {
			t.Logf("%s 请求失败: %v", item.label, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(response.Body, 8192))
		response.Body.Close()

		names := make([]string, 0, len(response.Header))
		for name := range response.Header {
			names = append(names, name)
		}
		sort.Strings(names)

		t.Logf("\n===== %s =====", item.label)
		t.Logf("status=%d proto=%s len=%d", response.StatusCode, response.Proto, len(content))
		for _, name := range names {
			values := response.Header[name]
			line := strings.Join(values, " | ")
			if len(line) > 300 {
				line = line[:300] + "..."
			}
			t.Logf("  %-28s %s", name, line)
		}
		head := string(content)
		if len(head) > 300 {
			head = head[:300]
		}
		t.Logf("  body: %s", head)
	}
}
