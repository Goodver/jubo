package protocol

import (
	"encoding/json"
	"strings"
	"testing"

	"duanjuapp/native/ohg/internal/drm"
)

// 2026-11-08 现场取证：新剧《下山送信竟成了国公府赘婿》第 1 集的明文
// representation 只有 gear_des_key(1:normal) 和 check_info，没有 encrypt_info；
// 正常竖版剧则有 encrypt_info{cenc-aes-ctr, spade_a} + gear_des_key(1:encrypt)。
// 早先把 check_info / gear_des_key 一律当成加密标记，导致明文分集被判成
// 受保护、KeyMaterial 为空，drm.Derive("") 报 unrecognized key material。

func playbackEnvelope(t *testing.T, items ...map[string]any) []byte {
	t.Helper()
	model := map[string]any{
		"video_id":       "v03d0fg10004dbld7ma7dldb4a84qovg",
		"media_type":     "video",
		"video_duration": 120.0,
		"video_list":     items,
	}
	inner, err := json.Marshal(model)
	if err != nil {
		t.Fatal(err)
	}
	env := map[string]any{
		"code":    0,
		"message": "请求成功",
		"data":    map[string]any{"video_model": string(inner)},
	}
	out, err := json.Marshal(env)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func clearItem(url string) map[string]any {
	return map[string]any{
		"main_url":     url,
		"gear_des_key": "0:MP4|1:normal|2:h265_hvc1|4:360p|5:normal|10000:105",
		"check_info":   map[string]any{"check_info": "c:0-120423-6455"},
		"video_meta": map[string]any{
			"codec_type": "bytevc1", "definition": "360p",
			"vwidth": 640, "vheight": 360, "bitrate": 620423,
		},
	}
}

func encryptedItem(url string) map[string]any {
	return map[string]any{
		"main_url": url,
		"encrypt_info": map[string]any{
			"encrypt":           true,
			"encryption_method": "cenc-aes-ctr",
			"kid":               "6ae198a6476d5a0530d10df50003ebeb",
			"spade_a":           "k7wd8VO+GfBWigbFSYsF21SXH+xTlRnrSZMB20+iAd5TlBu+vg==",
		},
		"gear_des_key": "0:MP4|1:encrypt|2:h265_hvc1|4:360p|5:normal|6:only_roi_audio_64k_v194|10000:105",
		"check_info":   map[string]any{"check_info": "c:0-58979-bc7e"},
		"video_meta": map[string]any{
			"codec_type": "bytevc1", "definition": "360p",
			"vwidth": 360, "vheight": 640, "bitrate": 392477,
		},
	}
}

func TestParsePlaybackClearModelIsNotProtected(t *testing.T) {
	raw := playbackEnvelope(t,
		clearItem("https://cdn.example/clear-360.mp4"),
		clearItem("https://cdn.example/clear-480.mp4"),
	)
	pb, err := ParsePlayback(raw, "7704205696497110041")
	if err != nil {
		t.Fatalf("ParsePlayback: %v", err)
	}
	if pb.Protected {
		t.Fatal("明文播放模型被误判成受保护")
	}
	if pb.KeyMaterial != "" {
		t.Fatalf("明文模型不该有密钥材料: %q", pb.KeyMaterial)
	}
	if len(pb.Streams) != 2 {
		t.Fatalf("streams=%d, want 2", len(pb.Streams))
	}
	for i, s := range pb.Streams {
		if s.Protected {
			t.Errorf("stream[%d] 被误判成加密", i)
		}
		if s.URL == "" {
			t.Errorf("stream[%d] 丢失地址", i)
		}
	}
}

func TestParsePlaybackEncryptedModelStillProtected(t *testing.T) {
	raw := playbackEnvelope(t,
		encryptedItem("https://cdn.example/enc-360.mp4"),
		encryptedItem("https://cdn.example/enc-480.mp4"),
	)
	pb, err := ParsePlayback(raw, "7702046361570528281")
	if err != nil {
		t.Fatalf("ParsePlayback: %v", err)
	}
	if !pb.Protected {
		t.Fatal("加密播放模型没有被识别")
	}
	if !strings.HasPrefix(pb.KeyMaterial, "k7wd8VO+") {
		t.Fatalf("密钥材料读取异常: %q", pb.KeyMaterial)
	}
	for i, s := range pb.Streams {
		if !s.Protected || s.Encryption != "cenc-aes-ctr" {
			t.Errorf("stream[%d] protected=%v method=%q", i, s.Protected, s.Encryption)
		}
	}
	key, err := drm.Derive(pb.KeyMaterial)
	if err != nil {
		t.Fatalf("drm.Derive: %v", err)
	}
	if len(key.Hex) != 32 {
		t.Fatalf("内容密钥长度=%d, want 32", len(key.Hex))
	}
}

// 即使将来又冒出「有加密标记但没有 spade_a」的模型，也不该把流判死：
// 没有 encryption_method 时会降级成明文，有明确方案标记时保持受保护。
func TestParsePlaybackMissingKeyMaterialFallsBack(t *testing.T) {
	item := encryptedItem("https://cdn.example/odd.mp4")
	info := item["encrypt_info"].(map[string]any)
	delete(info, "spade_a")
	delete(info, "encryption_method")
	info["encrypt"] = true
	delete(item, "gear_des_key")

	pb, err := ParsePlayback(playbackEnvelope(t, item), "1")
	if err != nil {
		t.Fatalf("ParsePlayback: %v", err)
	}
	if pb.Protected {
		t.Fatal("无密钥材料且无加密方案的模型应降级为明文")
	}
	if pb.Streams[0].Protected {
		t.Fatal("流仍标记为加密")
	}
}
