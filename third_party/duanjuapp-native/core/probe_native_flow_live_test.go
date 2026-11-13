//go:build live

package core

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

// 端到端走 FFI 同款入口 NativeRequest（JSON in / JSON out），把安卓 App 启动后
// 真正会发的调用串一遍：initialize → catalog → search → detail → resolve。
// 这条路径与手机上 libhgnative.so 的 HgRequest 完全一致。
//
//	go test -tags live ./core/ -run TestLiveNativeRequestFlow -v -timeout 280s
func TestLiveNativeRequestFlow(t *testing.T) {
	call := func(payload map[string]any) map[string]any {
		body, _ := json.Marshal(payload)
		started := time.Now()
		raw := NativeRequest(string(body))
		var result map[string]any
		if err := json.Unmarshal([]byte(raw), &result); err != nil {
			t.Fatalf("%v -> 返回不是 JSON: %s", payload["action"], truncate(raw, 200))
		}
		if ok, _ := result["ok"].(bool); !ok {
			t.Fatalf("%v 失败 (%s): %s", payload["action"], time.Since(started).Round(time.Millisecond), truncate(raw, 300))
		}
		t.Logf("%-16s ok (%s)", payload["action"], time.Since(started).Round(time.Millisecond))
		return result
	}

	call(map[string]any{"action": "initialize", "directory": t.TempDir()})

	rawCatalog := NativeRequest(`{"action":"catalog","source":"hongguo","page":1,"category":""}`)
	t.Logf("catalog 原始返回前 300 字: %s", truncate(rawCatalog, 300))
	catalog := call(map[string]any{"action": "catalog", "source": "hongguo", "page": 1, "category": ""})
	data, _ := catalog["data"].(map[string]any)
	dramas, _ := data["items"].([]any)
	t.Logf("目录返回 %d 部", len(dramas))
	if len(dramas) == 0 {
		t.Fatal("目录为空")
	}
	first, _ := dramas[0].(map[string]any)
	t.Logf("首部: %v (%v)", first["title"], first["id"])

	search := call(map[string]any{"action": "catalog", "source": "hongguo", "query": "霸总", "page": 1})
	sdata, _ := search["data"].(map[string]any)
	hits, _ := sdata["items"].([]any)
	t.Logf("搜索返回 %d 部", len(hits))

	if len(hits) == 0 {
		t.Fatal("搜索为空")
	}
	target, _ := hits[0].(map[string]any)
	seriesID, _ := target["id"].(string)
	t.Logf("目标剧: %v id=%s", target["title"], seriesID)

	rawDetail := NativeRequest(fmt.Sprintf(`{"action":"detail","source":"hongguo","drama":{"id":%q}}`, seriesID))
	t.Logf("detail 原始返回前 400 字: %s", truncate(rawDetail, 400))
	detail := call(map[string]any{"action": "detail", "source": "hongguo", "drama": map[string]any{"id": seriesID}})
	ddetail, _ := detail["data"].(map[string]any)
	if ddetail == nil {
		ddetail = detail
	}
	drama, _ := ddetail["drama"].(map[string]any)
	chapters, _ := ddetail["chapters"].([]any)
	if drama == nil {
		drama = map[string]any{}
	}
	t.Logf("详情: %v 共 %d 集", firstNonEmpty(mapString(drama, "title"), asText(target["title"])), len(chapters))
	if len(chapters) == 0 {
		t.Fatal("没有剧集")
	}
	chapter, _ := chapters[0].(map[string]any)
	t.Logf("首集: %v videoUrl=%v", chapter["title"], chapter["videoUrl"])

	plan := call(map[string]any{
		"action": "resolve", "source": "hongguo", "sequence": 101,
		"drama":   map[string]any{"id": seriesID},
		"chapter": chapter,
	})
	if pdata, ok := plan["data"].(map[string]any); ok {
		plan = pdata
	}
	url, _ := plan["url"].(string)
	key, _ := plan["decryptionKey"].(string)
	t.Logf("playback url=%s", truncate(url, 90))
	t.Logf("cenc key=%s quality=%v qualities=%v session=%v", key, plan["quality"], plan["qualities"], truncate(asText(plan["session"]), 12))
	if !strings.HasPrefix(url, "http://127.0.0.1:") {
		t.Fatalf("播放地址没有经过本机流服务: %s", url)
	}
	if len(key) != 32 {
		t.Fatalf("CENC key 长度异常: %q", key)
	}
}

func asText(value any) string {
	text, _ := value.(string)
	return text
}
