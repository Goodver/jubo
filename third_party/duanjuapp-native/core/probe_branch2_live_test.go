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

// exe 的 HG_DUMP_SIGN 日志里，10 条请求有 9 条是 branch=2（另 1 条 branch=0），
// 而工程只在生成时「避开 branch 1」，没有要求落在 2。
// sign.tuneBranch 就是 exe 用来把分支调到服务端接受值的那一步。
//
// 这里强制 branch==2 后再发。
//
//	go test -tags live ./core/ -run TestLiveBranch2 -v -timeout 180s
func TestLiveBranch2(t *testing.T) {
	videoID := "7698761405498936345"
	host := "https://api5-normal-lq.fqnovel.com"
	deviceID := "621699152495976"
	iid := "780026313179920"

	const playbackUA = "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
	const playbackVersion = "7.1.3.32"

	body := hongguoMediaPayload(videoID)
	khronos := uint32(time.Now().Unix())
	baseTicket := uint64(time.Now().UnixMilli())

	var rawURL, query string
	var ticket uint64
	var branch uint32
	for offset := uint64(0); offset < 256; offset++ {
		ticket = baseTicket + offset
		query = hongguoPlaybackQuery(deviceID, iid, khronos, ticket)
		rawURL = host + hongguoMultiVideoPath + "?" + query
		branch = hongguoBranchOf(rawURL, body, khronos)
		if branch == 2 {
			break
		}
	}
	t.Logf("branch=%d ticket=%d", branch, ticket)

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

	request, err := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
	if err != nil {
		t.Fatalf("构造失败: %v", err)
	}
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	client := &http.Client{Timeout: 15 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		t.Fatalf("请求失败: %v", err)
	}
	content, _ := io.ReadAll(io.LimitReader(response.Body, 8192))
	response.Body.Close()
	note := ""
	if bytes.Contains(content, []byte("video_model")) {
		note = "  <<== 命中 video_model"
	}
	head := string(content)
	if len(head) > 200 {
		head = head[:200]
	}
	t.Logf("HTTP=%d len=%-5d%s %s", response.StatusCode, len(content), note, head)
}
