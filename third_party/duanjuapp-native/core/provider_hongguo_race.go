package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 红果取流的多线路竞速。
//
// 1.2.20 的处理方式是「各设备/线路同时取播放地址，谁先成功用谁」，并记住哪条
// 线路能用（exe 里有 hostPicker 的 markGood/markBad）。这里按同样的思路实现，
// 但分两轮，避免一上来就把所有身份都撒出去：
//
//	第 1 轮：当前最健康的设备身份 × 前 4 条线路，并发，最先拿到可用
//	         video_list 的胜出，其余立刻取消。
//	第 2 轮：第 1 轮全失败时，用 **整个设备池**的其余身份再扫一遍。用户填了
//	         自定义 did/uid 时，该身份已排在第 1 轮，不再留到这一轮。
//	         实测 playback 接口会对
//	         被用狠的身份静默返回空 body，而池里靠后的身份仍能出流，所以这一轮
//	         必须覆盖全池，不能只取前几个。
//
// 后面仍保留 provider_hongguo.go 里原有的网页取流与第三方备用接口兜底。

var hongguoPlayHosts = []string{
	"https://api5-normal-lq.fqnovel.com",
	"https://api5-normal-lf.fqnovel.com",
	"https://api5-normal-hl.fqnovel.com",
	"https://api3-normal-lq.fqnovel.com",
	"https://api3-normal-lf.fqnovel.com",
	"https://api3-normal-hl.fqnovel.com",
	"https://api5-normal-sinfonlineb.fqnovel.com",
	"https://api5-normal.fqnovel.com",
}

var hongguoHostHealth = struct {
	sync.Mutex
	score map[string]int
}{score: map[string]int{}}

// hongguoSilentLimit 记录主接口「200 + 空 body」的连续轮次。
//
// 2026-11-07 实机实测：服务端整体静默限流时，换设备身份（含用户手机红果的
// 真实 did）、换 8 条线路、切 Wi-Fi/5G、IPv4/IPv6、HTTP2/HTTP1.1 全部返回
// 空包；此时继续跑完三轮竞速 + 网页 + 备用只会把设备额度继续打空、拉长恢复
// 时间。连续两轮全空后进入 10 分钟冷却，冷却期内只发 1 个探测请求。
var hongguoSilentLimit = struct {
	sync.Mutex
	streak int
	until  time.Time
}{}

func hongguoSilentCooldown() bool {
	hongguoSilentLimit.Lock()
	defer hongguoSilentLimit.Unlock()
	return time.Now().Before(hongguoSilentLimit.until)
}

func hongguoNoteSilentEmpty(detail string) {
	if !strings.Contains(detail, "空内容") {
		return
	}
	hongguoSilentLimit.Lock()
	defer hongguoSilentLimit.Unlock()
	hongguoSilentLimit.streak++
	if hongguoSilentLimit.streak >= 2 {
		hongguoSilentLimit.until = time.Now().Add(10 * time.Minute)
		hongguoSilentLimit.streak = 0
	}
}

func hongguoNotePlaybackSuccess() {
	hongguoSilentLimit.Lock()
	defer hongguoSilentLimit.Unlock()
	hongguoSilentLimit.streak = 0
	hongguoSilentLimit.until = time.Time{}
}

// hongguoDeviceHealth 记录哪些设备身份还能取到流。
//
// 实测（2026-11-03 19:20）：playback 接口会对「用得太狠」的设备身份静默返回
// 200 + 空 body，而同一时刻其它身份照常出流。这个状态是按身份累积的，且和
// IP 无关（切蜂窝无用）。因此必须像线路那样记住好坏，否则每轮都先把已经
// 失效的身份撞一遍。
var hongguoDeviceHealth = struct {
	sync.Mutex
	score map[string]int
}{score: map[string]int{}}

func hongguoMarkDevice(name string, ok bool) {
	hongguoDeviceHealth.Lock()
	defer hongguoDeviceHealth.Unlock()
	if hongguoDeviceHealth.score == nil {
		hongguoDeviceHealth.score = map[string]int{}
	}
	if ok {
		hongguoDeviceHealth.score[name]++
		if hongguoDeviceHealth.score[name] > 8 {
			hongguoDeviceHealth.score[name] = 8
		}
		return
	}
	hongguoDeviceHealth.score[name] -= 3
	if hongguoDeviceHealth.score[name] < -12 {
		hongguoDeviceHealth.score[name] = -12
	}
}

// hongguoOrderedPlayDevices 按健康分排序，同分保持原顺序。
func hongguoOrderedPlayDevices(pool []hongguoDeviceProfile) []hongguoDeviceProfile {
	devices := append([]hongguoDeviceProfile(nil), pool...)
	hongguoDeviceHealth.Lock()
	defer hongguoDeviceHealth.Unlock()
	sort.SliceStable(devices, func(i, j int) bool {
		return hongguoDeviceHealth.score[devices[i].Name] > hongguoDeviceHealth.score[devices[j].Name]
	})
	return devices
}

func hongguoMarkHost(host string, ok bool) {
	hongguoHostHealth.Lock()
	defer hongguoHostHealth.Unlock()
	if hongguoHostHealth.score == nil {
		hongguoHostHealth.score = map[string]int{}
	}
	if ok {
		hongguoHostHealth.score[host]++
		if hongguoHostHealth.score[host] > 8 {
			hongguoHostHealth.score[host] = 8
		}
		return
	}
	hongguoHostHealth.score[host] -= 3
	if hongguoHostHealth.score[host] < -12 {
		hongguoHostHealth.score[host] = -12
	}
}

// hongguoOrderedPlayHosts 按健康分排序，同分保持配置顺序（sort.SliceStable）。
func hongguoOrderedPlayHosts() []string {
	hosts := append([]string(nil), hongguoPlayHosts...)
	hongguoHostHealth.Lock()
	defer hongguoHostHealth.Unlock()
	sort.SliceStable(hosts, func(i, j int) bool {
		return hongguoHostHealth.score[hosts[i]] > hongguoHostHealth.score[hosts[j]]
	})
	return hosts
}

type hongguoPlayAttempt struct {
	device hongguoDeviceProfile
	host   string
}

func (attempt hongguoPlayAttempt) label() string {
	return attempt.device.Name + " @" + strings.TrimPrefix(strings.TrimPrefix(attempt.host, "https://"), "http://")
}

type hongguoPlayResult struct {
	media  providerMedia
	err    error
	label  string
	host   string
	device string
}

func (d *Downloader) hongguoPlaybackWaves() [][]hongguoPlayAttempt {
	// 设备按健康分排序：能出流的身份优先，被风控的身份往后排。
	pool := hongguoOrderedPlayDevices(hongguoDevicePool())
	if len(pool) == 0 {
		return nil
	}
	// 用户填了自己手机的 did 时，把它排在第一轮。主身份一旦被风控，按原顺序
	// 要先白跑两轮（1 次 + 2 次换线路）才轮到第三轮的自定义设备；而用户自己
	// 真实注册过的设备号才是当下最可能可用的身份，没理由排在最后。
	if custom, ok := d.currentPlaybackDevice().profile(); ok {
		pool = append([]hongguoDeviceProfile{custom}, pool...)
	}
	hosts := hongguoOrderedPlayHosts()
	primary := pool[0]

	var waves [][]hongguoPlayAttempt
	// 第一轮只发 1 个请求。playback 接口是按设备身份计额度/风控的，
	// 一上来就并发打 4 条线路等于把额度消耗放大 4 倍，正常情况下 1 个就够。
	waves = append(waves, []hongguoPlayAttempt{{device: primary, host: hosts[0]}})

	// 第二轮换线路（同一身份），只有第一轮失败才走。
	if len(hosts) > 1 {
		alt := hosts[1:]
		if len(alt) > 2 {
			alt = alt[:2]
		}
		wave := make([]hongguoPlayAttempt, 0, len(alt))
		for _, host := range alt {
			wave = append(wave, hongguoPlayAttempt{device: primary, host: host})
		}
		waves = append(waves, wave)
	}

	// 第三轮换设备身份：必须覆盖整个设备池。池里带 token 的主力身份和最早几个
	// 变体最容易被风控盯上（实测前 4 个全空、后 4 个仍可用），只取前几个会永远
	// 轮不到能用的。
	// 自定义设备（若配置）已经作为 pool[0] 在第一、二轮试过，这里只扫内置身份，
	// 避免同一身份在一轮里被重复发送、白耗额度。
	devices := append([]hongguoDeviceProfile(nil), pool[1:]...)
	if len(devices) > 0 {
		wave := make([]hongguoPlayAttempt, 0, 6)
		for _, device := range devices {
			if len(wave) >= 6 {
				break
			}
			wave = append(wave, hongguoPlayAttempt{device: device, host: hosts[0]})
		}
		waves = append(waves, wave)
	}
	return waves
}

func (d *Downloader) raceHongguoPlayback(ctx context.Context, videoID string) (providerMedia, error) {
	waves := d.hongguoPlaybackWaves()
	if len(waves) == 0 {
		return providerMedia{}, errors.New("红果取流没有可用的设备身份")
	}
	cooldown := hongguoSilentCooldown()
	if cooldown && len(waves) > 1 {
		// 限流冷却期只留 1 个探测请求，不再把整池身份和所有线路撒出去。
		waves = waves[:1]
	}
	var failures []string
	for _, wave := range waves {
		if err := ctx.Err(); err != nil {
			return providerMedia{}, err
		}
		media, detail := d.runHongguoWave(ctx, videoID, wave)
		if detail == "" {
			hongguoNotePlaybackSuccess()
			return media, nil
		}
		failures = append(failures, detail)
	}
	joined := strings.Join(failures, "；")
	hongguoNoteSilentEmpty(joined)
	if cooldown {
		return providerMedia{}, errors.New("红果播放接口仍在限流冷却中（已自动减少重试请求）；请间隔约 10 分钟再试")
	}
	return providerMedia{}, errors.New(joined)
}

// runHongguoWave 并发打一整轮，最先返回可用媒体的胜出；detail 非空表示整轮失败，
// 里面是各次尝试的失败原因（已去重、已截断）。
func (d *Downloader) runHongguoWave(ctx context.Context, videoID string, attempts []hongguoPlayAttempt) (providerMedia, string) {
	if len(attempts) == 0 {
		return providerMedia{}, ""
	}
	waveCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	results := make(chan hongguoPlayResult, len(attempts))
	for _, attempt := range attempts {
		attempt := attempt
		go func() {
			// 子 goroutine 的 panic 不会被 NativeRequest 的顶层 recover 捕获，
			// 不兜住就会直接终止整个进程（表现为无提示闪退）。
			defer func() {
				if recovered := recover(); recovered != nil {
					results <- hongguoPlayResult{
						err:    fmt.Errorf("取流内部错误: %v", recovered),
						label:  attempt.label(),
						host:   attempt.host,
						device: attempt.device.Name,
					}
				}
			}()
			media, err := d.hongguoFetchMedia(waveCtx, videoID, attempt)
			results <- hongguoPlayResult{media: media, err: err, label: attempt.label(), host: attempt.host, device: attempt.device.Name}
		}()
	}
	seen := map[string]bool{}
	reasons := make([]string, 0, 4)
	for index := 0; index < len(attempts); index++ {
		select {
		case <-ctx.Done():
			return providerMedia{}, publicError(ctx.Err()).Error()
		case result := <-results:
			if result.err == nil {
				hongguoMarkHost(result.host, true)
				hongguoMarkDevice(result.device, true)
				cancel()
				return result.media, ""
			}
			hongguoMarkHost(result.host, false)
			hongguoMarkDevice(result.device, false)
			reason := publicError(result.err).Error()
			if !seen[reason] && len(reasons) < 4 {
				seen[reason] = true
				reasons = append(reasons, reason)
			}
		}
	}
	if len(reasons) == 0 {
		return providerMedia{}, "红果取流全部线路均失败"
	}
	return providerMedia{}, strings.Join(reasons, "；")
}

func (d *Downloader) doPlaybackRequest(request *http.Request, timeout time.Duration) (*http.Response, error) {
	ctx, cancel := context.WithTimeout(request.Context(), timeout)
	response, err := d.client.Do(request.WithContext(ctx))
	if err != nil {
		cancel()
		return nil, err
	}
	response.Body = &limitedResponseBody{ReadCloser: response.Body, release: cancel}
	return response, nil
}

func (d *Downloader) hongguoFetchMedia(ctx context.Context, videoID string, attempt hongguoPlayAttempt) (providerMedia, error) {
	call := hongguoBuildMediaCall(attempt.device, attempt.host, videoID)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, call.url, bytes.NewReader(call.body))
	if err != nil {
		return providerMedia{}, err
	}
	for name, value := range call.headers {
		request.Header.Set(name, value)
	}
	response, err := d.doPlaybackRequest(request, 12*time.Second)
	if err != nil {
		return providerMedia{}, err
	}
	content, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	response.Body.Close()
	if readErr != nil {
		return providerMedia{}, readErr
	}
	if response.StatusCode != http.StatusOK {
		return providerMedia{}, fmt.Errorf("取流接口 HTTP %d", response.StatusCode)
	}
	result, err := decodeHongguoMediaModel(content)
	if err != nil {
		return providerMedia{}, err
	}
	model, err := hongguoMediaModelEntry(result, videoID)
	if err != nil {
		return providerMedia{}, err
	}
	// multi_video_model 自身就已经带完整 video_list（main_url + spade_a + 加密信息），
	// 实测能直接选出可播放的 hvc1 1080P 流。优先走这条直达路径，省掉一次
	// fallback_api 往返（那次往返只带 UA + Cookie，没有签名套件，很容易被判空）。
	if media, directErr := selectHongguoAppMedia(model); directErr == nil {
		return media, nil
	}
	address := hongguoFallbackAddress(model)
	if address == "" {
		return providerMedia{}, errors.New("红果未提供清晰度接口地址")
	}
	info, err := d.hongguoFallbackInfo(ctx, attempt.device, address)
	if err != nil {
		return providerMedia{}, err
	}
	return hongguoMediaFromVideoInfo(model, info)
}

func decodeHongguoMediaModel(content []byte) (map[string]any, error) {
	if len(content) == 0 {
		// 平台收紧播放接口后，未被认可的请求会拿到 200 + 空 body。
		// 2026-11-07 实机：整体静默限流时，换 did / 换线路 / 换 IP / 换协议
		// 全都还是空包，此时再提示「填自己的 did」只会误导用户反复重试、
		// 把设备额度继续打空。改成如实说明并引导降频。
		return nil, errors.New("红果取流接口返回空内容（平台限流或设备身份未被认可）：请间隔几分钟再试，连续重试会延长限流")
	}
	if len(content) > providerMaxBodyBytes {
		return nil, errors.New("红果取流接口未返回有效数据")
	}
	var result map[string]any
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	if err := decoder.Decode(&result); err != nil || result == nil {
		return nil, errors.New("红果取流接口返回格式异常")
	}
	code := firstNonEmpty(mapString(result, "code", "Code", "status_code"), mapString(nestedMap(result, "BaseResp"), "StatusCode"))
	if code != "" && code != "0" {
		message := firstNonEmpty(mapString(result, "message", "err_msg", "errmsg", "msg"), mapString(nestedMap(result, "BaseResp"), "StatusMessage"))
		if message != "" {
			return nil, fmt.Errorf("取流接口暂不可用（%s: %s）", truncate(code, 20), truncate(message, 120))
		}
		return nil, fmt.Errorf("取流接口暂不可用（%s）", truncate(code, 20))
	}
	return result, nil
}

func hongguoMediaFromVideoInfo(model, info map[string]any) (providerMedia, error) {
	videoList, _ := info["video_list"].(map[string]any)
	if len(videoList) == 0 {
		return providerMedia{}, errors.New("红果未返回可用的清晰度列表")
	}
	seed, _ := hongguoDecodeBase64URLSafe(mapString(info, "key_seed"))
	rows := hongguoQualityRows(videoList)
	if len(rows) == 0 {
		return providerMedia{}, errors.New("红果清晰度列表没有可播放地址")
	}
	duration, _ := strconv.ParseFloat(mapString(model, "video_duration", "duration"), 64)
	var keyErr error
	type scoredMedia struct {
		media providerMedia
		rank  int
	}
	var choices []scoredMedia
	for _, row := range rows {
		address := mapString(row.item, "main_url")
		if len(seed) > 0 && address != "" {
			decrypted, decryptErr := hongguoSpadeAddress(address, seed)
			if decryptErr != nil {
				keyErr = decryptErr
				continue
			}
			address = decrypted
		}
		if !isProviderHTTPMediaURL(address) {
			continue
		}
		meta := nestedMap(row.item, "video_meta")
		codec := strings.ToLower(mapString(meta, "codec_type"))
		if codec == "bytevc2" {
			continue
		}
		media := providerMedia{
			URL:      address,
			Referer:  "https://novel.snssdk.com/",
			Duration: time.Duration(duration * float64(time.Second)),
		}
		if spade := mapString(row.item, "spade_a"); spade != "" {
			key, keyErrValue := hongguoContentKey(spade)
			if keyErrValue != nil {
				keyErr = keyErrValue
				continue
			}
			media.CENCKey = key
		}
		media.Quality = hongguoMediaQualityNumber(row.quality)
		media.Codec = codec
		choices = append(choices, scoredMedia{media: media, rank: providerCodecRank(codec)})
	}
	if len(choices) == 0 {
		if keyErr != nil {
			return providerMedia{}, fmt.Errorf("红果媒体密钥不可用: %w", keyErr)
		}
		return providerMedia{}, errors.New("红果未返回兼容的媒体，已跳过不支持的编码")
	}
	sort.SliceStable(choices, func(i, j int) bool {
		if choices[i].rank != choices[j].rank {
			return choices[i].rank < choices[j].rank
		}
		return choices[i].media.Quality > choices[j].media.Quality
	})
	selected := choices[0].media
	for _, choice := range choices {
		selected.Variants = append(selected.Variants, choice.media)
	}
	return selected, nil
}
