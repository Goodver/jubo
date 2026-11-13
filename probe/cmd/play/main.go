package main

import (
	"encoding/json"
	"fmt"
	"os"

	"duanjuapp/native/core"
)

func call(input map[string]any) map[string]any {
	body, _ := json.Marshal(input)
	raw := core.NativeRequest(string(body))
	var out map[string]any
	if json.Unmarshal([]byte(raw), &out) != nil {
		return map[string]any{"ok": false, "error": raw}
	}
	return out
}

func main() {
	dir := os.Args[1]
	_ = os.MkdirAll(dir, 0o755)
	fmt.Println("init:", call(map[string]any{"action": "initialize", "directory": dir})["ok"])

	type sample struct {
		id       string
		title    string
		category string
	}
	samples := []sample{
		{"hongguo:7701226234214108185", "聚宝仙盆之杂灵根才是真BOSS第十五季", "漫剧"},
		{"hongguo:7697622096326708286", "退役归来，这个保镖不好惹", "AI剧"},
		{"hongguo:7701935931787316286", "十八岁太奶奶驾到，重整家族荣耀第五部", "真人剧"},
	}

	for _, s := range samples {
		drama := map[string]any{
			"id":       s.id,
			"source":   "hongguo",
			"sourceId": s.id[len("hongguo:"):],
			"title":    s.title,
			"category": s.category,
			"cover":    "",
		}
		detail := call(map[string]any{"action": "detail", "drama": drama})
		ok := detail["ok"]
		data, _ := detail["data"].(map[string]any)
		chapters, _ := data["chapters"].([]any)
		fmt.Printf("\n[detail %s] ok=%v chapters=%d err=%v\n", s.category, ok, len(chapters), detail["error"])
		if len(chapters) == 0 {
			continue
		}
		first, _ := chapters[0].(map[string]any)
		title := ""
		n := 0
		for _, c := range chapters {
			n++
			_ = c
		}
		_ = title
		plan := call(map[string]any{
			"action":   "resolve",
			"drama":    drama,
			"chapter":  first,
			"index":    n - n + 1,
			"quality":  0,
			"sequence": 1,
		})
		pdata, _ := plan["data"].(map[string]any)
		url, _ := pdata["url"].(string)
		key, _ := pdata["decryptionKey"].(string)
		qs, _ := pdata["qualities"].([]any)
		if len(url) > 72 {
			url = url[:72] + "…"
		}
		if len(key) > 12 {
			key = key[:12] + "…"
		}
		fmt.Printf("[resolve %s] ok=%v url=%q key=%q qualities=%v err=%v\n", s.category, plan["ok"], url, key, qs, plan["error"])
	}
}
