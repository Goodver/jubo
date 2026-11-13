//go:build live

package core

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// 端到端验证：完全走生产代码的 hongguoBuildMediaCall 构造请求，
// 真实打一次取流接口，确认拿到 code:0 与可播放的 main_url。
//
//	go test -tags live ./core/ -run TestLiveProductionMedia -v -timeout 120s
func TestLiveProductionMedia(t *testing.T) {
	const videoID = "7686525480618429465"
	const host = "https://api5-normal-lq.fqnovel.com"

	device := hongguoDevicePool()[0]
	call := hongguoBuildMediaCall(device, host, videoID)

	request, err := http.NewRequest(http.MethodPost, call.url, bytes.NewReader(call.body))
	if err != nil {
		t.Fatal(err)
	}
	for name, value := range call.headers {
		request.Header.Set(name, value)
	}
	client := &http.Client{Timeout: 20 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		t.Fatalf("请求失败: %v", err)
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
	t.Logf("status=%d len=%d", response.StatusCode, len(content))
	if len(content) == 0 {
		t.Fatalf("空响应，签名或头仍不对")
	}

	result, err := decodeHongguoMediaModel(content)
	if err != nil {
		t.Fatalf("解析失败: %v (%s)", err, string(content[:min(200, len(content))]))
	}
	if code, _ := result["code"].(json.Number); code.String() != "0" {
		t.Fatalf("业务失败: %s", string(content[:min(300, len(content))]))
	}
	model, err := hongguoMediaModelEntry(result, videoID)
	if err != nil {
		t.Fatalf("取 video_model 失败: %v", err)
	}
	t.Logf("video_id=%v duration=%v", model["video_id"], model["video_duration"])
	list, _ := model["video_list"].([]any)
	if len(list) == 0 {
		t.Fatalf("video_list 为空")
	}
	first, _ := list[0].(map[string]any)
	t.Logf("main_url=%v", mapString(first, "main_url"))
	if mapString(first, "main_url") == "" {
		t.Fatalf("没有 main_url")
	}
}
