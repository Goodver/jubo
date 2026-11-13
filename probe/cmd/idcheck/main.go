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
	call(map[string]any{"action": "initialize", "directory": dir})
	res := call(map[string]any{"action": "catalog", "source": "hongguo", "page": 1})
	data, _ := res["data"].(map[string]any)
	items, _ := data["items"].([]any)
	fmt.Println("items:", len(items), "hasMore:", data["hasMore"], "page:", data["page"])
	for i, row := range items {
		if i >= 4 {
			break
		}
		m, _ := row.(map[string]any)
		fmt.Printf("id=%v source=%v sourceId=%v title=%v eps=%v\n", m["id"], m["source"], m["sourceId"], m["title"], m["episodes"])
	}
}
