//go:build live

package core

import (
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// 头集合严格对齐：反汇编 sign.Values.Headers（0x14047b7a0）后取到的头名只有
//
//	X-Khronos X-SS-Stub X-Gorgon X-Helios X-Medusa X-SS-Req-Ticket
//	X-TT-Trace-Id X-Argus X-Ladon
//
// 而当前工程额外发了 Sdk-Version / Passport-Sdk-Version /
// X-VC-BDTuring-SDK-Version / X-TT-Request-Tag / X-XS-From-Web，
// 这五个 exe 从不发送；同时缺 X-TT-Trace-Id。
//
//	go test -tags live ./core/ -run TestLiveExactHeaders -v -timeout 180s
func TestLiveExactHeaders(t *testing.T) {
	videoID := "7698761405498936345"
	host := "https://api5-normal-lq.fqnovel.com"
	deviceID := "621699152495976"
	iid := "780026313179920"

	const (
		playbackUA      = "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
		playbackVersion = "7.1.3.32"
		traceID         = "00-8f3a1c2d4e5b6a70-9c0d1e2f3a4b5c60-01"
	)

	cases := []struct {
		label      string
		trace      bool
		fullExtra  bool
		withAccept bool
	}{
		{"① 只发 exe 名单（无TraceId）", false, false, false},
		{"② exe 名单 + TraceId", true, false, false},
		{"③ exe 名单 + TraceId + Accept", true, false, true},
		{"④ 现状（多5个头，无TraceId）", false, true, true},
	}

	client := &http.Client{Timeout: 15 * time.Second}
	for _, item := range cases {
		khronos := uint32(time.Now().Unix())
		ticket := uint64(time.Now().UnixMilli())
		query := hongguoPlaybackQuery(deviceID, iid, khronos, ticket)
		rawURL := host + hongguoMultiVideoPath + "?" + query
		body := hongguoMediaPayload(videoID)

		random := hongguoRandom32() % 65536
		sum := md5.Sum(body)
		headers := map[string]string{
			"User-Agent":        playbackUA,
			"Content-Type":      hongguoMediaContentType,
			"X-Khronos":         fmt.Sprintf("%d", khronos),
			"X-SS-Req-Ticket":   fmt.Sprintf("%d", ticket),
			"X-SS-Stub":         strings.ToUpper(hex.EncodeToString(sum[:])),
			"X-Gorgon":          hongguoXGorgon(query, body, khronos, random),
			"X-Helios":          hongguoHelios(khronos),
			"X-Medusa":          hongguoBuildMedusa(rawURL, body, khronos, deviceID, playbackVersion),
		}
		if item.trace {
			headers["X-TT-Trace-Id"] = traceID
		}
		if item.withAccept {
			headers["Accept"] = hongguoAcceptHeader
		}
		if item.fullExtra {
			headers["X-XS-From-Web"] = "0"
			headers["X-TT-Request-Tag"] = hongguoTtRequestTag
			headers["Sdk-Version"] = hongguoSdkVersion
			headers["Passport-Sdk-Version"] = hongguoPassportSdkVer
			headers["X-VC-BDTuring-SDK-Version"] = hongguoBdturingVersion
			headers["X-Argus"] = "AAAA"
			headers["X-Ladon"] = "AAAA"
		}

		request, err := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
		if err != nil {
			t.Fatalf("构造失败: %v", err)
		}
		for name, value := range headers {
			request.Header.Set(name, value)
		}
		response, err := client.Do(request)
		if err != nil {
			t.Logf("%-32s 请求失败: %v", item.label, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(response.Body, 8192))
		response.Body.Close()
		note := ""
		if bytes.Contains(content, []byte("video_model")) {
			note = "  <<== 命中 video_model"
		}
		head := string(content)
		if len(head) > 140 {
			head = head[:140]
		}
		t.Logf("%-32s HTTP=%d len=%-5d%s %s", item.label, response.StatusCode, len(content), note, head)
		time.Sleep(300 * time.Millisecond)
	}
}
