package core

import (
	"testing"
	"time"

	"duanjuapp/native/ohg"
)

// 新引擎的播放模型必须能映射成调用方已有的 providerMedia 语义：
// 最高画质优先、跳过不支持的编码、加密流带 CENC key、备用地址进 Variants。
func TestOHGResultToMedia(t *testing.T) {
	key := "00112233445566778899aabbccddeeff"
	result := &ohg.Result{
		EpisodeID:     "7400000000000000001",
		Duration:      95 * time.Second,
		Protected:     true,
		ContentKeyHex: key,
		Streams: []ohg.Stream{
			{URL: "https://cdn.example.com/720.mp4", Definition: "720p", Height: 720, Codec: "h264", Protected: true},
			{URL: "https://cdn.example.com/1080.mp4", BackupURL: "https://backup.example.com/1080.mp4", Definition: "1080p", Height: 1080, Codec: "hvc1", Protected: true},
			{URL: "https://cdn.example.com/bytevc2.mp4", Definition: "2160p", Height: 2160, Codec: "bytevc2", Protected: true},
		},
	}
	media, err := ohgResultToMedia(result)
	if err != nil {
		t.Fatalf("转换播放模型失败: %v", err)
	}
	if media.URL != "https://cdn.example.com/1080.mp4" {
		t.Fatalf("没有选中 1080P 主地址: %s", media.URL)
	}
	if media.Quality != 1080 || media.Codec != "hvc1" {
		t.Fatalf("画质或编码不对: quality=%d codec=%s", media.Quality, media.Codec)
	}
	if media.Referer != "https://novel.snssdk.com/" || media.Duration != 95*time.Second {
		t.Fatalf("Referer/Duration 不对: %s / %s", media.Referer, media.Duration)
	}
	if len(media.CENCKey) != 16 || len(media.Variants) != 3 {
		t.Fatalf("CENC key 或清晰度列表不对: key=%d variants=%d", len(media.CENCKey), len(media.Variants))
	}
	for _, variant := range media.Variants {
		if variant.Codec == "bytevc2" {
			t.Fatal("不支持的 bytevc2 编码混进了清晰度列表")
		}
		if len(variant.CENCKey) != 16 {
			t.Fatal("加密清晰度缺少 CENC key")
		}
	}
}

// 2026-11-08：明文分集（video_list 里没有 encrypt_info / spade_a）不该被
// 要求 CENC key。《下山送信竟成了国公府赘婿》第 1 集就是这种模型，修复前
// 会被误判成加密并在 drm.Derive("") 处整集失败。
func TestOHGResultToMediaClearStreams(t *testing.T) {
	result := &ohg.Result{
		EpisodeID: "7704205696497110041",
		Duration:  120 * time.Second,
		Protected: false,
		Streams: []ohg.Stream{
			{URL: "https://cdn.example.com/360.mp4", Height: 360, Codec: "bytevc1"},
			{
				URL:       "https://cdn.example.com/480.mp4",
				BackupURL: "https://backup.example.com/480.mp4",
				Height:    480,
				Codec:     "bytevc1",
			},
		},
	}
	media, err := ohgResultToMedia(result)
	if err != nil {
		t.Fatalf("明文播放模型转换失败: %v", err)
	}
	if media.URL != "https://cdn.example.com/480.mp4" {
		t.Fatalf("没有选中最高清晰度: %s", media.URL)
	}
	if len(media.CENCKey) != 0 {
		t.Fatalf("明文流不该带 CENC key: %d 字节", len(media.CENCKey))
	}
	for _, variant := range media.Variants {
		if len(variant.CENCKey) != 0 {
			t.Fatal("明文清晰度不该带 CENC key")
		}
	}
}

func TestOHGResultToMediaRejectsInvalidInput(t *testing.T) {
	if _, err := ohgResultToMedia(nil); err == nil {
		t.Fatal("空播放模型没有被拒绝")
	}
	if _, err := ohgResultToMedia(&ohg.Result{}); err == nil {
		t.Fatal("没有流地址的播放模型没有被拒绝")
	}
	if _, err := ohgResultToMedia(&ohg.Result{
		ContentKeyHex: "not-hex",
		Streams:       []ohg.Stream{{URL: "https://cdn.example.com/a.mp4"}},
	}); err == nil {
		t.Fatal("非法内容密钥没有被拒绝")
	}
	if _, err := ohgResultToMedia(&ohg.Result{
		Streams: []ohg.Stream{{URL: "ftp://cdn.example.com/a.mp4"}},
	}); err == nil {
		t.Fatal("非 HTTP 媒体地址没有被拒绝")
	}
}
