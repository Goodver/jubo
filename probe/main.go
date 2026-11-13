package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"

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
	fmt.Println("initialize:", brief(init, 300))

	for _, source := range []string{"hongguo", "huangguoai"} {
		cats := call(map[string]any{"action": "categories", "source": source})
		fmt.Printf("\n[categories %s] ok=%v err=%v\n", source, cats["ok"], brief(cats["error"], 200))
		if data, ok := cats["data"].(map[string]any); ok {
			if items, ok := data["items"].([]any); ok {
				for _, row := range items {
					if m, ok := row.(map[string]any); ok {
						fmt.Printf("   %-16s %v\n", brief(m["id"], 16), m["name"])
					}
				}
			}
		}
	}

	type probe struct {
		source   string
		category string
	}
	probes := []probe{
		{"hongguo", "short_play"},
		{"hongguo", "comic_series"},
		{"hongguo", "ai_series"},
		{"hongguo", ""},
		{"huangguoai", ""},
		{"huangguoai", "ai-manju"},
	}
	for _, p := range probes {
		input := map[string]any{"action": "catalog", "source": p.source, "page": 1}
		if p.category != "" {
			input["category"] = p.category
		}
		res := call(input)
		count := 0
		titles := []string{}
		catCount := map[string]int{}
		if data, ok := res["data"].(map[string]any); ok {
			if items, ok := data["items"].([]any); ok {
				count = len(items)
				for i, row := range items {
					m, _ := row.(map[string]any)
					if m == nil {
						continue
					}
					catCount[fmt.Sprint(m["category"])]++
					if i < 5 {
						titles = append(titles, fmt.Sprint(m["title"]))
					}
				}
			}
		}
		label := p.source
		if p.category != "" {
			label += "/" + p.category
		}
		fmt.Printf("\n[catalog %s] ok=%v count=%d err=%v\n", label, res["ok"], count, brief(res["error"], 160))
		if len(catCount) > 0 {
			keys := make([]string, 0, len(catCount))
			for k := range catCount {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				fmt.Printf("   category=%-14s %d\n", k, catCount[k])
			}
		}
		if len(titles) > 0 {
			fmt.Printf("   例：%v\n", titles)
		}
	}
}
