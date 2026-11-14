// Package ohg 把 openhongguo 匿名播放 SDK 嵌入本引擎。
//
// 源码来自 github.com/beilunyang/openhongguo，Apache License 2.0，
// 完整许可见同目录 LICENSE。本包是一层薄封装：对外只暴露自有类型，
// 不暴露 SDK 内部类型，让 core 能在不改变 JSON action 接口的前提下
// 把取流实现整体换成「现场注册匿名设备 + 现役客户端协议」。
//
// 之所以要换：红果服务端自 2026-10-29 起会对用过的匿名设备返回 200 + 空 body，
// 写死的设备池迟早耗尽额度，只有现场注册新设备、并在空结果时自动换设备才是
// 可持续的解法。
//
// 2026-11-14 在创维上实测修正了上面这句的一半：同一份档案连续取流并没有被判空
// （第 1 集 1270ms、第 2 集 308ms 都成功），所以「一台设备只给一次」不成立。
// 真正会遇到的是档案放久之后整体失效，此时必须靠换设备救回来 —— 这条路径的成功
// 与否由 trace.go 带进错误串，否则现场完全不可见。
package ohg

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"duanjuapp/native/ohg/adapters"
	"duanjuapp/native/ohg/adapters/filestore"
	"duanjuapp/native/ohg/sdk"
)

// Stream 是播放模型里的一个清晰度/编码表示形式。
type Stream struct {
	URL        string
	BackupURL  string
	Definition string
	Quality    string
	Codec      string
	Height     int
	Width      int
	Bitrate    int64
	HLS        bool
	Dash       bool
	Protected  bool
	Encryption string
}

// Result 是一次取流的结果。ContentKeyHex 是 CENC（cenc-aes-ctr）
// 内容密钥的小写十六进制形式，调用方需要自行解码成字节。
type Result struct {
	EpisodeID     string
	VideoID       string
	Duration      time.Duration
	ExpiresAt     int64
	AudioURL      string
	Streams       []Stream
	ContentKeyHex string
	Protected     bool
	// Rotations 是这次取流为了拿到结果换掉了几台匿名设备，0 表示首台设备
	// 直接成功。它是判断「档案健康度」的唯一现成指标：长期非 0 说明档案
	// 频繁被判失效，需要做主动轮换。调用方只用于日志，不参与播放决策。
	Rotations int
}

// Engine 持有一个跨调用复用的匿名设备客户端。设备档案由 filestore
// 持久化，空结果时 SDK 会丢弃档案、注册新设备并重试。
type Engine struct {
	mu     sync.Mutex
	client *sdk.Client
	guard  *playbackGuard
	trace  *traceLog
}

// New 用 profilePath 作为匿名设备档案的持久化位置创建引擎。
// profilePath 应指向 App 的可写数据目录。
func New(profilePath string) (*Engine, error) {
	if strings.TrimSpace(profilePath) == "" {
		return nil, errors.New("匿名设备档案路径为空")
	}
	engine := &Engine{guard: newPlaybackGuard(), trace: &traceLog{}}
	client, err := adapters.NewClient(profilePath, sdk.Options{
		// 限流/传输类失败重发一次；签名时间仍在有效期内。
		RetryAttempts: 2,
		// 空结果或设备被拒时最多换两台新设备重试。
		DeviceResets: sdk.Int(2),
		// 包一层档案存储，统计实际换了几台设备；同时接上 SDK 的诊断输出，
		// 失败时随错误一起回给 Dart（见 trace.go）。
		ProfileStore: countStore{inner: filestore.New(profilePath), trace: engine.trace},
		Logger:       engine.trace,
	})
	if err != nil {
		return nil, fmt.Errorf("初始化匿名播放引擎失败: %w", err)
	}
	engine.client = client
	return engine, nil
}

// Resolve 取一集的播放模型。加密分集会连同 ErrDRMProtected 返回，
// 这里把它当作正常结果，并顺带还原内容密钥。
//
// 串行化是为了避免并发预加载同时抢注多台设备：服务端按设备计额度，
// 并发请求各自换设备只会互相把对方的额度打空。
func (e *Engine) Resolve(ctx context.Context, episodeID string) (*Result, error) {
	if e == nil || e.client == nil {
		return nil, errors.New("匿名播放引擎尚未初始化")
	}
	id := strings.TrimSpace(episodeID)
	if id == "" {
		return nil, errors.New("分集 ID 为空")
	}
	e.mu.Lock()
	defer e.mu.Unlock()

	// 节奏链 + 熔断：连续空结果时先暂停，别把设备额度继续打空。
	probe, guardErr := e.guard.acquire(ctx)
	if guardErr != nil {
		return nil, guardErr
	}
	defer e.guard.release(probe)

	// 本次取流的诊断只记这一次：换设备次数与 SDK 的告警行。
	e.trace.begin()

	pb, err := e.client.ResolvePlayback(ctx, id, sdk.PlaybackOptions{})
	if err != nil && !errors.Is(err, sdk.ErrDRMProtected) {
		if errors.Is(err, sdk.ErrAnonymousLimited) {
			e.guard.reportEmpty()
		}
		return nil, fmt.Errorf("匿名设备取流失败: %w；%s", err, e.trace.summary())
	}
	if pb == nil {
		e.guard.reportEmpty()
		return nil, fmt.Errorf("匿名设备取流返回空播放模型；%s", e.trace.summary())
	}
	e.guard.reportOK()
	out := &Result{
		EpisodeID: pb.EpisodeID,
		VideoID:   pb.VideoID,
		Duration:  time.Duration(pb.DurationSeconds) * time.Second,
		ExpiresAt: pb.ExpiresAt,
		AudioURL:  pb.AudioURL,
		Protected: pb.Protected,
		Rotations: e.trace.rotations(),
		Streams:   make([]Stream, 0, len(pb.Streams)),
	}
	for _, s := range pb.Streams {
		out.Streams = append(out.Streams, Stream{
			URL:        strings.TrimSpace(s.URL),
			BackupURL:  strings.TrimSpace(s.BackupURL),
			Definition: s.Definition,
			Quality:    s.Quality,
			Codec:      s.Codec,
			Height:     s.Height,
			Width:      s.Width,
			Bitrate:    s.Bitrate,
			HLS:        s.HLS,
			Dash:       s.Dash,
			Protected:  s.Protected,
			Encryption: s.Encryption,
		})
	}
	if len(out.Streams) == 0 {
		return nil, fmt.Errorf("播放模型没有可用的流地址；%s", e.trace.summary())
	}
	if pb.Protected {
		key, keyErr := sdk.ContentKey(pb)
		if keyErr != nil {
			return nil, fmt.Errorf("还原加密分集内容密钥失败: %w", keyErr)
		}
		out.ContentKeyHex = key.Hex
	}
	return out, nil
}

// Reset 主动丢弃当前匿名设备并注册一台新设备。
func (e *Engine) Reset(ctx context.Context) error {
	if e == nil || e.client == nil {
		return errors.New("匿名播放引擎尚未初始化")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	e.trace.begin()
	if err := e.client.ResetDevice(ctx); err != nil {
		return fmt.Errorf("换匿名设备失败: %w；%s", err, e.trace.summary())
	}
	return nil
}
