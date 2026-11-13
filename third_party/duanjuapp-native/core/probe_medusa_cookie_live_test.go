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

// 在 query 与头都已对齐 exe 的前提下，收窄最后两个变量：
//   - Medusa 的 version 参数：播放会话 query 里是 7.1.3.32，但 Signer 的 AppProfile
//     可能仍用应用版本 7.3.9.32
//   - install_id Cookie：playbackSessionIID 会把借来的 iid 写进 Cookie
//
//	go test -tags live ./core/ -run TestLiveMedusaCookie -v -timeout 180s
func TestLiveMedusaCookie(t *testing.T) {
	videoID := "7698761405498936345"
	host := "https://api5-normal-lq.fqnovel.com"
	deviceID := "621699152495976"
	iid := "780026313179920"

	const playbackUA = "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

	cases := []struct {
		label       string
		medusaVer   string
		cookie      string
		withCookie  bool
	}{
		{"① Medusa 7.3.9.32 无 Cookie", hongguoMediaVersion, "", false},
		{"② Medusa 7.3.9.32 + install_id", hongguoMediaVersion, "install_id=" + iid, true},
		{"③ Medusa 7.1.3.32 + install_id", "7.1.3.32", "install_id=" + iid, true},
		{"④ Medusa 7.3.9.32 + install_id+uid_tt", hongguoMediaVersion, "install_id=" + iid + "; uid_tt=", true},
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
			"User-Agent":      playbackUA,
			"Content-Type":    hongguoMediaContentType,
			"X-Khronos":       fmt.Sprintf("%d", khronos),
			"X-SS-Req-Ticket": fmt.Sprintf("%d", ticket),
			"X-SS-Stub":       strings.ToUpper(hex.EncodeToString(sum[:])),
			"X-Gorgon":        hongguoXGorgon(query, body, khronos, random),
			"X-Helios":        hongguoHelios(khronos),
			"X-Medusa":        hongguoBuildMedusa(rawURL, body, khronos, deviceID, item.medusaVer),
		}
		if item.withCookie {
			headers["Cookie"] = item.cookie
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
			t.Logf("%-34s 请求失败: %v", item.label, err)
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
		t.Logf("%-34s HTTP=%d len=%-5d%s %s", item.label, response.StatusCode, len(content), note, head)
		time.Sleep(300 * time.Millisecond)
	}
}
