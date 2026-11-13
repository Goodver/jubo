//go:build live

package core

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"testing"
	"time"
)

// 身份自洽性对照：之前所有探针都在用「混搭身份」——
// device_id 取自 spares[0]，install_id / device_token / ttreq 却来自 auto，
// UA 与 device_type 也不一致。服务端对此类档案可以直接判异常并静默返回空。
//
// 这里把 hgplayer.db 里 7 套完整身份逐条原样发送，每套的 device_id /
// install_id / cdid / openudid / UA / device_token / ttreq 全部同源。
//
//	go test -tags live ./core/ -run TestLiveIdentityMatrix -v -timeout 180s
type hongguoIdentityFixture struct {
	Label       string `json:"label"`
	DeviceID    string `json:"device_id"`
	InstallID   string `json:"install_id"`
	CDID        string `json:"cdid"`
	OpenUDID    string `json:"openudid"`
	Brand       string `json:"brand"`
	Model       string `json:"model"`
	OSVersion   string `json:"os_version"`
	OSAPI       string `json:"os_api"`
	Resolution  string `json:"resolution"`
	DPI         string `json:"dpi"`
	UserAgent   string `json:"user_agent"`
	Channel     string `json:"channel"`
	DeviceToken string `json:"device_token"`
	TtReq       string `json:"ttreq"`
	StoreRegion string `json:"store_region"`
}

func (item hongguoIdentityFixture) profile() hongguoDeviceProfile {
	return hongguoDeviceProfile{
		Name: item.Label, Brand: item.Brand, Model: item.Model,
		OSVersion: item.OSVersion, OSAPI: item.OSAPI,
		Resolution: item.Resolution, DPI: item.DPI,
		Channel: item.Channel, UserAgent: item.UserAgent,
		HostABI: "arm64-v8a",
		DeviceID: item.DeviceID, InstallID: item.InstallID, IID: item.InstallID,
		CDID: item.CDID, OpenUDID: item.OpenUDID,
		DeviceToken: item.DeviceToken, TtReq: item.TtReq,
		StoreRegion: item.StoreRegion, TokenBound: true,
	}
}

func TestLiveIdentityMatrix(t *testing.T) {
	raw, err := os.ReadFile("testdata/identities.json")
	if err != nil {
		t.Fatalf("读不到身份表: %v", err)
	}
	var identities []hongguoIdentityFixture
	if err := json.Unmarshal(raw, &identities); err != nil {
		t.Fatalf("身份表解析失败: %v", err)
	}

	videoID := "7698761405498936345"
	host := "https://api5-normal-lq.fqnovel.com"
	client := &http.Client{Timeout: 15 * time.Second}

	for _, item := range identities {
		device := item.profile()
		rawURL, body, headers, _ := probeMediaCall(device, host, videoID, hongguoMediaVersion, "")
		request, err := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
		if err != nil {
			t.Logf("%-8s 构造失败: %v", item.Label, err)
			continue
		}
		for name, value := range headers {
			request.Header.Set(name, value)
		}
		response, err := client.Do(request)
		if err != nil {
			t.Logf("%-8s 请求失败: %v", item.Label, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(response.Body, 8192))
		response.Body.Close()
		note := ""
		if bytes.Contains(content, []byte("video_model")) {
			note = "  <<== 命中 video_model"
		}
		head := string(content)
		if len(head) > 120 {
			head = head[:120]
		}
		t.Logf("%-8s did=%-17s HTTP=%d len=%-5d%s %s", item.Label, item.DeviceID, response.StatusCode, len(content), note, head)
		// 成功即刻停止，避免把有效身份打进风控
		if len(content) > 0 {
			break
		}
	}
}
