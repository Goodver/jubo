package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"duanjuapp/native/core"
)

func call(input map[string]any) (map[string]any, error) {
	body, _ := json.Marshal(input)
	start := time.Now()
	raw := core.NativeRequest(string(body))
	var out map[string]any
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return nil, fmt.Errorf("非法响应: %v raw=%.300s", err, raw)
	}
	ok, _ := out["ok"].(bool)
	if !ok {
		return out, fmt.Errorf("%v", out["error"])
	}
	fmt.Printf("  [%s] %.2fs\n", input["action"], time.Since(start).Seconds())
	return out, nil
}

func main() {
	dir := os.Args[1]
	fmt.Println("=== initialize ===")
	out, err := call(map[string]any{"action": "initialize", "directory": dir})
	fmt.Println("  ", out, err)

	fmt.Println("=== catalog hongguo ===")
	out, err = call(map[string]any{"action": "catalog", "source": "hongguo", "page": 1})
	if err != nil {
		fmt.Println("  失败:", err)
		return
	}
	data, _ := out["data"].(map[string]any)
	items, _ := data["items"].([]any)
	fmt.Printf("   条目 %d, 键: ", len(items))
	for k := range data {
		fmt.Print(k, " ")
	}
	fmt.Println()
	if len(items) == 0 {
		return
	}
	first, _ := items[0].(map[string]any)
	fmt.Printf("   首条: %v\n", first["title"])
	for k, v := range first {
		s := fmt.Sprint(v)
		if len(s) > 80 {
			s = s[:80] + "…"
		}
		fmt.Printf("     %-16s %s\n", k, s)
	}

	fmt.Println("=== detail ===")
	out, err = call(map[string]any{"action": "detail", "drama": first})
	if err != nil {
		fmt.Println("  失败:", err)
		return
	}
	d, _ := out["data"].(map[string]any)
	eps, _ := d["chapters"].([]any)
	fmt.Printf("   剧集 %d\n", len(eps))
	if len(eps) == 0 {
		return
	}
	ep, _ := eps[0].(map[string]any)
	fmt.Printf("   首集: %v\n", ep)

	fmt.Println("=== resolve ===")
	out, err = call(map[string]any{"action": "resolve", "drama": first, "chapter": ep, "index": ep["currentEpisode"], "quality": 0, "sequence": 1})
	if err != nil {
		fmt.Println("  失败:", err)
		return
	}
	plan, _ := out["data"].(map[string]any)
	for k, v := range plan {
		s := fmt.Sprint(v)
		if len(s) > 160 {
			s = s[:160] + "…"
		}
		fmt.Printf("     %-14s %s\n", k, s)
	}
}
