//go:build live

package core

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"testing"
	"time"
)

// 目录接口探针：定位 /reading/distribution/category/landpage/v/ 的真实参数形状。
// 400 响应会直接回吐字段校验错误，据此逐项修正。
//
//	go test -tags live ./core/ -run TestLiveCatalogProbe -v -timeout 120s
func TestLiveCatalogProbe(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader
	client := d.hongguoClient()
	base := client.baseURL
	device := hongguoDevicePool()[0]

	type variant struct {
		label    string
		scene    string
		genre    string
		reqType  string
		clientRT int
		randomID bool // true 表示像生产路径那样把 device_id/iid 换成随机生成值
	}

	variants := []variant{
		{label: "comic/native", scene: "comic_series", genre: "comic_series", reqType: "only_content", clientRT: 3},
		{label: "comic/randID", scene: "comic_series", genre: "comic_series", reqType: "only_content", clientRT: 3, randomID: true},
	}

	for _, item := range variants {
		payload := map[string]any{
			"req_scene": item.scene, "offset": 0, "limit": 18,
			"req_type": item.reqType, "need_selector_panel": false, "client_req_type": item.clientRT,
			"session_id": "", "filter_ids": "",
			"select_items": map[string]any{
				"genre": []string{item.genre}, "sort": []string{"online_time"}, "gender": []string{},
				"category_dim_theme": []string{}, "category_dim_role": []string{}, "category_dim_epoch": []string{},
				"online_time": []string{}, "creation_status": []string{},
			},
		}
		body, _ := json.Marshal(payload)
		now := time.Now()
		sendDevice := device
		deviceID, installID := client.state.DeviceID, client.state.InstallID
		if item.randomID {
			deviceID = newHongguoDeviceID()
			installID = newHongguoDeviceID()
			sendDevice.DeviceID = deviceID
			sendDevice.InstallID = installID
			sendDevice.IID = installID
		}
		query := url.Values{
			"aid": {"8662"}, "app_name": {"novelread"}, "version_code": {"73532"}, "version_name": {"7.3.5.32"},
			"manifest_version_code": {"73532"}, "update_version_code": {"73532"}, "channel": {"update_64"},
			"device_platform": {"android"}, "os": {"android"}, "ssmix": {"a"}, "device_type": {"25053RT47C"},
			"device_brand": {"Redmi"}, "language": {"zh"}, "os_api": {"36"}, "os_version": {"16"},
			"resolution": {"1280*2772"}, "dpi": {"520"}, "ac": {"wifi"},
			"device_id": {deviceID}, "iid": {installID},
			"_rticket": {strconv.FormatInt(now.UnixMilli(), 10)},
		}
		target := base + "/reading/distribution/category/landpage/v/?" + query.Encode()
		request, _ := http.NewRequestWithContext(context.Background(), http.MethodPost, target, bytes.NewReader(body))
		request.Header.Set("User-Agent", hongguoAppUserAgent)
		request.Header.Set("Accept", "application/json")
		request.Header.Set("Content-Type", "application/json; charset=utf-8")
		for name, value := range hongguoSignSuite(sendDevice, target, body, uint32(now.Unix()), uint64(now.UnixMilli())) {
			request.Header.Set(name, value)
		}
		request.Header.Set("User-Agent", hongguoAppUserAgent)
		request.Header.Set("Accept", "application/json")

		httpClient := &http.Client{Timeout: 20 * time.Second}
		response, reqErr := httpClient.Do(request)
		if reqErr != nil {
			t.Logf("%-16s err=%v", item.label, reqErr)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		response.Body.Close()
		prefix := string(content)
		if len(prefix) > 200 {
			prefix = prefix[:200]
		}
		t.Logf("%-16s status=%d len=%d %s", item.label, response.StatusCode, len(content), prefix)
	}
}
