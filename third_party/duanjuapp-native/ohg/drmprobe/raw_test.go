package drmprobe

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"duanjuapp/native/ohg/adapters"
	"duanjuapp/native/ohg/sdk"
)

// TestDRMRaw 抓播放模型的原始响应，只打印加密相关字段的键与值，
// 不打印 CDN 地址。用来确认服务端把密钥材料放在了哪个字段。
func TestDRMRaw(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	client, err := adapters.NewClient(t.TempDir()+"/profile.json", sdk.Options{
		RetryAttempts: 2,
		DeviceResets:  sdk.Int(2),
	})
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	ids := os.Getenv("OHG_PROBE_EPISODES")
	if ids == "" {
		// 失败剧第 1 集 / 正常剧第 1 集
		ids = "7704205696497110041,7702046361570528281"
	}
	for _, id := range strings.Split(ids, ",") {
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		t.Logf("=== RAW episodeID=%s ===", id)
		raw, err := client.RawPlayback(ctx, id)
		if err != nil {
			t.Logf("  RawPlayback FAILED: %v", err)
			continue
		}
		t.Logf("  response bytes=%d", len(raw))
		var env struct {
			Code    any `json:"code"`
			Message string `json:"message"`
			Data    struct {
				VideoModel json.RawMessage `json:"video_model"`
			} `json:"data"`
		}
		if err := json.Unmarshal(raw, &env); err != nil {
			t.Logf("  envelope unmarshal: %v", err)
			continue
		}
		t.Logf("  code=%v message=%q", env.Code, env.Message)
		b := bytes.TrimSpace(env.Data.VideoModel)
		if len(b) > 0 && b[0] == '"' {
			var s string
			if err := json.Unmarshal(b, &s); err == nil {
				b = []byte(s)
			}
		}
		var video struct {
			VideoList json.RawMessage `json:"video_list"`
			Dynamic   json.RawMessage `json:"dynamic_video"`
		}
		if err := json.Unmarshal(b, &video); err != nil {
			t.Logf("  video_model unmarshal: %v (head=%s)", err, head(string(b), 200))
			continue
		}
		list := bytes.TrimSpace(video.VideoList)
		var items []json.RawMessage
		if len(list) > 0 && list[0] == '[' {
			_ = json.Unmarshal(list, &items)
		} else if len(list) > 0 && list[0] == '{' {
			var keyed map[string]json.RawMessage
			if json.Unmarshal(list, &keyed) == nil {
				for _, v := range keyed {
					items = append(items, v)
				}
			}
		}
		t.Logf("  video_list type=%c items=%d dynamic.bytes=%d",
			firstByte(list), len(items), len(video.Dynamic))
		for i, item := range items {
			if i >= 2 {
				break
			}
			var m map[string]any
			if err := json.Unmarshal(item, &m); err != nil {
				t.Logf("  item[%d] unmarshal: %v", i, err)
				continue
			}
			keys := make([]string, 0, len(m))
			for k := range m {
				keys = append(keys, k)
			}
			t.Logf("  item[%d] keys=%v", i, keys)
			for _, k := range []string{
				"encrypt_info", "spade_a", "kid", "gear_des_key",
				"check_info", "encryption_method", "encrypt",
				"vwidth", "vheight", "codec_type", "vtype", "definition",
			} {
				if v, ok := m[k]; ok {
					t.Logf("    %s = %s", k, head(jsonString(v), 220))
				}
			}
			if meta, ok := m["video_meta"]; ok {
				t.Logf("    video_meta = %s", head(jsonString(meta), 260))
			}
		}
	}
}

func firstByte(b []byte) byte {
	if len(b) == 0 {
		return '?'
	}
	return b[0]
}

func jsonString(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return "<marshal error>"
	}
	return string(b)
}
