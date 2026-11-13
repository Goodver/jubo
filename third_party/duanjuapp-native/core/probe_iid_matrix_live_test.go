//go:build live

package core

import (
	"bytes"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// 对照 1.2.21 playbackSessionIID 的三处差异，逐项验证：
//
//  1. UA 与 query 里的设备参数必须自洽
//     现状：UA 是 com.phoenix.read/73932 ... Xiaomi 14 ... Android 14，
//     query 却是 Redmi / 25053RT47C / os_version 16 / os_api 36。
//     1.2.21 的播放会话指纹是 71332 / 25053RT47C / Android 16，两者一致。
//
//  2. 播放会话会把 install_id 写进 Cookie（值 = 借来的 iid）
//     1.2.21：setCookie(CookieString(), "install_id", iid) → SetCookieString
//     现状：Cookie 只在填了 uid 时才有 uid_tt，没有 install_id。
//
//  3. altIIDArgs：设备上下文存在时，会把 iid 参数**置空**再试一次
//
//	go test -tags live ./core/ -run TestLiveIIDMatrix -v -timeout 180s
func TestLiveIIDMatrix(t *testing.T) {
	videoID := "7698761405498936345"
	host := "https://api5-normal-lq.fqnovel.com"

	// 官方 playbackSessionIID 里写死的播放指纹
	const (
		playbackUA      = "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
		playbackVersion = "7.1.3.32"
	)

	// 当前工程实际发出的身份
	current := hongguoDevicePool()[0]
	current.DeviceID = "3260526922310188"
	current.Brand = "Redmi"
	current.Model = "25053RT47C"
	current.OSVersion = "16"
	current.OSAPI = "36"
	current.Resolution = "1280*2772"
	current.DPI = "520"
	current.Channel = "update_64"

	// 与 1.2.21 播放会话一致的身份（UA 换成播放指纹）
	playback := current
	playback.UserAgent = playbackUA

	// altIIDArgs 的形态：iid 置空
	noIID := playback
	noIID.IID = ""

	type variant struct {
		label   string
		device  hongguoDeviceProfile
		version string
		cookie  string
	}
	cases := []variant{
		{"① 现状（旧UA + 无cookie）", current, hongguoMediaVersion, ""},
		{"② 播放UA + 版本对齐", playback, playbackVersion, ""},
		{"③ 播放UA + install_id cookie", playback, playbackVersion, "install_id=" + playback.IID},
		{"④ 播放UA + iid置空", noIID, playbackVersion, ""},
		{"⑤ 播放UA + cookie + iid置空", noIID, playbackVersion, "install_id=" + playback.IID},
		{"⑥ 旧UA + install_id cookie", current, hongguoMediaVersion, "install_id=" + current.IID},
	}

	client := &http.Client{Timeout: 15 * time.Second}
	for _, item := range cases {
		rawURL, body, headers, _ := probeMediaCall(item.device, host, videoID, item.version, item.cookie)
		request, err := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
		if err != nil {
			t.Logf("%-28s 构造失败: %v", item.label, err)
			continue
		}
		for name, value := range headers {
			request.Header.Set(name, value)
		}
		response, err := client.Do(request)
		if err != nil {
			t.Logf("%-28s 请求失败: %v", item.label, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		response.Body.Close()
		hit := ""
		if bytes.Contains(content, []byte("video_model")) {
			hit = "  <<== 命中 video_model"
		}
		t.Logf("%-28s HTTP=%d len=%-5d%s %s", item.label, response.StatusCode, len(content), hit, strings.TrimSpace(string(content))[:minInt(len(strings.TrimSpace(string(content))), 140)])
	}
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// probeMediaCall 与 hongguoBuildMediaCall 等价，但允许指定 Medusa 用的版本号、
// 覆盖 Cookie，用于 A/B 对照。
func probeMediaCall(device hongguoDeviceProfile, host, videoID, version, cookie string) (string, []byte, map[string]string, uint32) {
	body := hongguoMediaPayload(videoID)
	khronos := uint32(time.Now().Unix())
	baseTicket := uint64(time.Now().UnixMilli())
	var rawURL string
	var ticket uint64
	for offset := uint64(0); offset < 32; offset++ {
		ticket = baseTicket + offset
		query := hongguoDeviceQuery(device, khronos, ticket)
		rawURL = strings.TrimRight(host, "/") + hongguoMultiVideoPath + "?" + query
		if hongguoBranchOf(rawURL, body, khronos) != 1 {
			break
		}
	}
	headers := hongguoSignSuite(device, rawURL, body, khronos, ticket)
	headers["X-Medusa"] = hongguoBuildMedusa(rawURL, body, khronos, device.DeviceID, version)
	if cookie != "" {
		headers["Cookie"] = cookie
	}
	return rawURL, body, headers, khronos
}
