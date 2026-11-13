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
	"strings"
	"testing"
	"time"
)

// 用 exe 堆里抓到的**原始 body**（4 个真实 video id）+ 九头全套发一次，
// 排除「id 不存在导致空包」这个可能。
//
//	go test -tags live ./core/ -run TestLiveExactBody -v -timeout 120s
func TestLiveExactBody(t *testing.T) {
	host := "https://api5-normal-lq.fqnovel.com"
	deviceID := "621699152495976"
	iid := "428185093167591"
	playbackUA := "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
	playbackVersion := "7.1.3.32"

	// exe 实际发出的 body（逐字节）
	exactBody := []byte(`{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["7691759547454606361","7677944760518052888","7696831006501768216","7688252128082529342"]}}`)

	client := &http.Client{Timeout: 15 * time.Second}
	khronos := uint32(time.Now().Unix())
	ticket := uint64(time.Now().UnixMilli())
	query := hongguoPlaybackQuery(deviceID, iid, khronos, ticket)
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
		"X-Argus":         base64.StdEncoding.EncodeToString(hongguoBigEndian32(khronos)),
		"X-Ladon":         base64.StdEncoding.EncodeToString(hongguoLittleEndian32(khronos)),
	}

	request, err := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(exactBody))
	if err != nil {
		t.Fatal(err)
	}
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	response, err := client.Do(request)
	if err != nil {
		t.Fatalf("请求失败: %v", err)
	}
	content, _ := io.ReadAll(io.LimitReader(response.Body, 8192))
	response.Body.Close()
	t.Logf("status=%d len=%d logid=%s origin=%s",
		response.StatusCode, len(content),
		response.Header.Get("X-Tt-Logid"), response.Header.Get("X-Dsa-Origin-Status"))
	if len(content) > 0 {
		head := string(content)
		if len(head) > 600 {
			head = head[:600]
		}
		t.Logf("body: %s", head)
	}
}
