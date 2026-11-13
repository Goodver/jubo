package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"duanjuapp/native/core"
)

func call(input map[string]any) map[string]any {
	body, _ := json.Marshal(input)
	raw := core.NativeRequest(string(body))
	var out map[string]any
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return map[string]any{"ok": false, "error": raw}
	}
	return out
}

func brief(v any, limit int) string {
	s := fmt.Sprint(v)
	if len(s) > limit {
		return s[:limit] + "…"
	}
	return s
}

func main() {
	dir := os.Args[1]
	_ = os.MkdirAll(dir, 0o755)

	init := call(map[string]any{"action": "initialize", "directory": dir})
	fmt.Println("initialize:", brief(init, 200))

	catalog := call(map[string]any{
		"action": "catalog", "source": "hongguo", "page": 1, "category": "",
	})
	fmt.Println("catalog ok:", catalog["ok"], "err:", brief(catalog["error"], 200))
	data, _ := catalog["data"].(map[string]any)
	items, _ := data["items"].([]any)
	if len(items) == 0 {
		fmt.Println("catalog empty")
		return
	}
	drama, _ := items[0].(map[string]any)
	fmt.Println("drama:", drama["id"], drama["title"])

	detail := call(map[string]any{"action": "detail", "drama": drama})
	fmt.Println("detail ok:", detail["ok"], "err:", brief(detail["error"], 200))
	ddata, _ := detail["data"].(map[string]any)
	chapters, _ := ddata["chapters"].([]any)
	if len(chapters) == 0 {
		fmt.Println("no chapters")
		return
	}
	fmt.Println("chapters:", len(chapters))
	full, _ := ddata["drama"].(map[string]any)
	if full == nil {
		full = drama
	}

	for _, seq := range []int64{1, 2, 3} {
		start := time.Now()
		plan := call(map[string]any{
			"action": "resolve", "drama": full, "chapter": chapters[0],
			"index": 1, "quality": 0, "sequence": seq,
		})
		pdata, _ := plan["data"].(map[string]any)
		fmt.Printf("resolve seq=%d ok=%v cost=%v url=%v err=%v\n",
			seq, plan["ok"], time.Since(start).Round(time.Millisecond),
			brief(pdata["url"], 60), brief(plan["error"], 200))
	}

	// 换一部剧再试，确认是不是单剧问题
	if len(items) > 1 {
		d2, _ := items[1].(map[string]any)
		det2 := call(map[string]any{"action": "detail", "drama": d2})
		dd2, _ := det2["data"].(map[string]any)
		ch2, _ := dd2["chapters"].([]any)
		full2, _ := dd2["drama"].(map[string]any)
		if full2 == nil {
			full2 = d2
		}
		if len(ch2) > 0 {
			plan := call(map[string]any{
				"action": "resolve", "drama": full2, "chapter": ch2[0],
				"index": 1, "quality": 0, "sequence": 4,
			})
			pdata, _ := plan["data"].(map[string]any)
			fmt.Printf("resolve #2 %v ok=%v url=%v err=%v\n",
				d2["title"], plan["ok"], brief(pdata["url"], 60), brief(plan["error"], 200))
		}
	}
}
