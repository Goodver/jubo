package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"duanjuapp/native/core"
)

func call(input map[string]any) map[string]any {
	body, _ := json.Marshal(input)
	var out map[string]any
	json.Unmarshal([]byte(core.NativeRequest(string(body))), &out)
	return out
}

func boxes(data []byte, depth int) {
	for len(data) >= 8 && depth < 4 {
		size := int(binary.BigEndian.Uint32(data))
		kind := string(data[4:8])
		if size < 8 || size > len(data) {
			if kind == "moov" || kind == "trak" || kind == "mdia" || kind == "minf" || kind == "stbl" {
				size = len(data)
			} else {
				return
			}
		}
		fmt.Printf("%s%s (%d)\n", string(make([]byte, depth*2)), kind, size)
		switch kind {
		case "moov", "trak", "mdia", "minf", "stbl", "stsd":
			inner := data[8:size]
			if kind == "stsd" && len(inner) > 8 {
				inner = inner[8:]
			}
			boxes(inner, depth+1)
		}
		if size <= 0 {
			return
		}
		data = data[size:]
	}
}

func main() {
	dir := os.Args[1]
	call(map[string]any{"action": "initialize", "directory": dir})
	cat := call(map[string]any{"action": "catalog", "source": "hongguo", "page": 1})
	data, _ := cat["data"].(map[string]any)
	items, _ := data["items"].([]any)
	drama, _ := items[0].(map[string]any)
	det := call(map[string]any{"action": "detail", "drama": drama})
	dd, _ := det["data"].(map[string]any)
	chapters, _ := dd["chapters"].([]any)
	ep, _ := chapters[0].(map[string]any)
	plan := call(map[string]any{"action": "resolve", "drama": drama, "chapter": ep, "index": 1, "quality": 0, "sequence": 1})
	pd, _ := plan["data"].(map[string]any)
	url, _ := pd["url"].(string)
	fmt.Println("URL:", url)

	req, _ := http.NewRequest("GET", url, nil)
	req.Header.Set("Range", "bytes=0-4194303")
	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Println("请求失败:", err)
		return
	}
	defer resp.Body.Close()
	fmt.Println("HTTP:", resp.StatusCode, "Content-Type:", resp.Header.Get("Content-Type"), "Len:", resp.Header.Get("Content-Length"))
	buf := make([]byte, 4194304)
	n, _ := io.ReadFull(resp.Body, buf)
	fmt.Println("读取", n, "字节")
	fmt.Println("--- 关键 fourcc 扫描 ---")
	for _, pat := range []string{"encv", "enca", "avc1", "hvc1", "hev1", "sinf", "senc", "pssh", "schm", "tenc"} {
		c := 0
		first := -1
		b := []byte(pat)
		for i := 0; i+4 <= n; i++ {
			if buf[i] == b[0] && buf[i+1] == b[1] && buf[i+2] == b[2] && buf[i+3] == b[3] {
				c++
				if first < 0 {
					first = i
				}
			}
		}
		if c > 0 {
			fmt.Printf("  %-6s 出现 %d 次, 首个偏移 %d\n", pat, c, first)
		}
	}
}
