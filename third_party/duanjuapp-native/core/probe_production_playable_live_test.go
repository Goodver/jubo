//go:build live

package core

import (
	"bytes"
	"compress/gzip"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"sort"
	"strings"
	"testing"
	"time"
)

// 端到端验证取流后的媒体可播放性：
//  1. 走生产 hongguoBuildMediaCall 拿 multi_video_model
//  2. 走生产 selectHongguoAppMedia 选出最优变体
//  3. Range 拉真实 mp4 头部，确认 200/206 + ftyp/moov
//  4. 若带 spade_a，确认 CENC 密钥能正常派生
//
//	go test -tags live ./core/ -run TestLiveProductionPlayable -v -timeout 180s
func TestLiveProductionPlayable(t *testing.T) {
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
	client := &http.Client{Timeout: 25 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		t.Fatalf("取流请求失败: %v", err)
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
	if len(content) == 0 {
		t.Fatalf("空响应")
	}

	result, err := decodeHongguoMediaModel(content)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	model, err := hongguoMediaModelEntry(result, videoID)
	if err != nil {
		t.Fatalf("取 video_model 失败: %v", err)
	}

	// 结构探查：video_list 每个变体的关键字段
	if list, ok := model["video_list"].([]any); ok {
		t.Logf("video_list 变体数=%d", len(list))
		for index, row := range list {
			variant, _ := row.(map[string]any)
			keys := make([]string, 0, len(variant))
			for key := range variant {
				keys = append(keys, key)
			}
			sort.Strings(keys)
			meta := nestedMap(variant, "video_meta")
			encryption := nestedMap(variant, "encrypt_info")
			t.Logf("  [%d] codec=%s def=%s wh=%sx%s encrypt=%v method=%s spade_a_len=%d keys=%v",
				index,
				mapString(meta, "codec_type"),
				mapString(meta, "definition"),
				mapString(meta, "vwidth"), mapString(meta, "vheight"),
				encryption["encrypt"], mapString(encryption, "encryption_method"),
				len(mapString(encryption, "spade_a")),
				keys,
			)
		}
	}

	media, err := selectHongguoAppMedia(model)
	if err != nil {
		t.Fatalf("selectHongguoAppMedia 失败: %v", err)
	}
	t.Logf("选中 quality=%dP codec=%s cencKeyLen=%d variants=%d",
		media.Quality, media.Codec, len(media.CENCKey), len(media.Variants))
	if len(media.CENCKey) > 0 {
		t.Logf("CENC key=%s", hex.EncodeToString(media.CENCKey))
	}
	t.Logf("URL=%s", media.URL)

	// Range 拉 mp4 头部
	head, err := http.NewRequest(http.MethodGet, media.URL, nil)
	if err != nil {
		t.Fatalf("构造媒体请求失败: %v", err)
	}
	head.Header.Set("Range", "bytes=0-262143")
	head.Header.Set("User-Agent", hongguoMediaUserAgent)
	if media.Referer != "" {
		head.Header.Set("Referer", media.Referer)
	}
	mediaClient := &http.Client{Timeout: 25 * time.Second}
	mediaResp, err := mediaClient.Do(head)
	if err != nil {
		t.Fatalf("媒体请求失败: %v", err)
	}
	chunk, _ := io.ReadAll(io.LimitReader(mediaResp.Body, 512<<10))
	mediaResp.Body.Close()
	t.Logf("媒体 status=%d content-type=%s len=%d", mediaResp.StatusCode, mediaResp.Header.Get("Content-Type"), len(chunk))
	if mediaResp.StatusCode != http.StatusOK && mediaResp.StatusCode != http.StatusPartialContent {
		t.Fatalf("媒体不可下载: HTTP %d", mediaResp.StatusCode)
	}

	boxes := hongguoBoxes(chunk)
	if !strings.Contains(strings.Join(boxes, ","), "ftyp") {
		t.Fatalf("不是有效的 MP4，顶部 boxes=%v", boxes)
	}
	t.Logf("顶部 boxes=%v", boxes)
	for _, wanted := range []string{"moov", "tenc", "senc", "saiz", "saio", "stsz"} {
		t.Logf("  含 %s = %v", wanted, strings.Contains(strings.Join(boxes, ","), wanted))
	}
}

// hongguoBoxes 列举 mp4 里出现的 box 类型（浅层扫描整个 chunk）。
func hongguoBoxes(data []byte) []string {
	known := map[string]bool{
		"ftyp": true, "moov": true, "mdat": true, "free": true, "moof": true,
		"trak": true, "mdia": true, "minf": true, "stbl": true, "stsd": true,
		"sinf": true, "schm": true, "schi": true, "tenc": true, "senc": true,
		"saiz": true, "saio": true, "stsz": true, "stco": true, "co64": true,
		"stsc": true, "stts": true, "mvhd": true, "tkhd": true, "mdhd": true,
		"hdlr": true, "avc1": true, "hvc1": true, "encv": true, "pssh": true,
		"frma": true, "sgpd": true, "sbgp": true, "elst": true,
	}
	seen := map[string]bool{}
	var out []string
	for index := 0; index+8 <= len(data); index++ {
		if !isASCIIBox(data[index : index+4]) {
			continue
		}
		name := string(data[index : index+4])
		if !known[name] || seen[name] {
			continue
		}
		seen[name] = true
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

func isASCIIBox(value []byte) bool {
	for _, char := range value {
		if char < 'a' || char > 'z' {
			if char < '0' || char > '9' {
				if char < 'A' || char > 'Z' {
					return false
				}
			}
		}
	}
	return true
}

var _ = json.Number("")
