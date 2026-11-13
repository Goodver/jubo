package core

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"duanjuapp/native/ohg"
)

// ohgRuntime 持有嵌入的 openhongguo 匿名播放引擎。
//
// 引擎必须跨调用复用：它把注册到的匿名设备档案持久化在 App 数据目录，
// 空结果时由 SDK 自动丢弃档案、重新注册设备再试。若每次取流都新建引擎，
// 就会变成每次都注册一台新设备，白白放大请求量。
var ohgRuntime = struct {
	sync.Mutex
	path   string
	engine *ohg.Engine
}{}

// configureOHGProfile 在 nativeEngine 初始化时绑定设备档案的落盘位置。
func configureOHGProfile(directory string) {
	if strings.TrimSpace(directory) == "" {
		return
	}
	ohgRuntime.Lock()
	defer ohgRuntime.Unlock()
	ohgRuntime.path = filepath.Join(directory, "openhongguo-profile.json")
}

// ohgPlaybackEngine 懒初始化引擎。单元测试里直接构造 Downloader 而没有
// App 数据目录时，退回到系统临时目录，保证 PC 侧巡检仍可用。
func (d *Downloader) ohgPlaybackEngine() (*ohg.Engine, error) {
	ohgRuntime.Lock()
	defer ohgRuntime.Unlock()
	if ohgRuntime.engine != nil {
		return ohgRuntime.engine, nil
	}
	path := ohgRuntime.path
	if path == "" {
		dir := d.cfg.dataDir
		if dir == "" {
			dir = os.TempDir()
		}
		path = filepath.Join(dir, "openhongguo-profile.json")
	}
	engine, err := ohg.New(path)
	if err != nil {
		return nil, err
	}
	ohgRuntime.engine = engine
	return engine, nil
}

// resolveOHGMedia 用现场注册的匿名设备取播放模型，再转成 core 的 providerMedia。
// 这是当前红果取流的主链路：旧版 multi_video_model 只在它失败时兜底。
func (d *Downloader) resolveOHGMedia(ctx context.Context, videoID string) (providerMedia, error) {
	engine, err := d.ohgPlaybackEngine()
	if err != nil {
		return providerMedia{}, err
	}
	result, err := engine.Resolve(ctx, videoID)
	if err != nil {
		return providerMedia{}, fmt.Errorf("红果匿名设备取流失败：%w", err)
	}
	return ohgResultToMedia(result)
}

// ohgResultToMedia 把 SDK 的播放模型映射成 providerMedia，字段语义与
// selectHongguoAppMedia 保持一致，调用方（播放、下载、清晰度切换）无需改动。
func ohgResultToMedia(result *ohg.Result) (providerMedia, error) {
	if result == nil || len(result.Streams) == 0 {
		return providerMedia{}, errors.New("红果播放模型没有可用的流地址")
	}
	var key []byte
	if result.ContentKeyHex != "" {
		decoded, err := hex.DecodeString(result.ContentKeyHex)
		if err != nil || len(decoded) != 16 {
			return providerMedia{}, errors.New("红果内容密钥格式无效")
		}
		key = decoded
	}
	type scoredMedia struct {
		media providerMedia
		score int
	}
	var choices []scoredMedia
	seen := map[string]bool{}
	for _, stream := range result.Streams {
		codec := strings.ToLower(strings.TrimSpace(stream.Codec))
		if codec == "bytevc2" || codec == "bytevc3" {
			continue
		}
		height := stream.Height
		if height <= 0 {
			height = hongguoMediaQualityNumber(stream.Definition)
		}
		if height <= 0 {
			height = stream.Width
		}
		base := providerMedia{
			Referer:  "https://novel.snssdk.com/",
			Duration: result.Duration,
			Quality:  height,
			Codec:    codec,
		}
		if stream.Protected {
			base.CENCKey = key
		}
		score := height * 10
		if codec == "h264" || codec == "avc" || codec == "avc1" {
			score++
		}
		for _, address := range []string{stream.URL, stream.BackupURL} {
			address = strings.TrimSpace(address)
			if !isProviderHTTPMediaURL(address) || seen[address] {
				continue
			}
			seen[address] = true
			media := base
			media.URL = address
			choices = append(choices, scoredMedia{media: media, score: score})
		}
	}
	if len(choices) == 0 {
		return providerMedia{}, errors.New("红果播放模型没有兼容的媒体地址")
	}
	sort.SliceStable(choices, func(i, j int) bool { return choices[i].score > choices[j].score })
	selected := choices[0].media
	for _, choice := range choices {
		selected.Variants = append(selected.Variants, choice.media)
	}
	return selected, nil
}
