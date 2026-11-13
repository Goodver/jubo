package core

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 红果多清晰度取流：multi_video_model 取模型 → fallback_api 取清晰度列表 →
// spade URL 解密 → spade_a 派生 CENC 内容密钥。签名头与参数顺序均需与客户端一致。

const (
	hongguoMultiVideoPath = "/novel/player/multi_video_model/v1/"
	// 取流请求用的是「播放设备」这一套字段：UA 71332 + Redmi 25053RT47C / Android 16 /
	// 1280*2772 / dpi 520，version_name 7.1.3.32。这套值来自 exe 真实发出的请求
	// （GODEBUG=http2debug=2 抓到的 :path 与头部），与注册设备（Xiaomi 14 / 73932）是两套身份。
	hongguoMediaUserAgent = "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
	hongguoMediaVersion   = "7.1.3.32"
	// 播放设备固定字段（query 里的 device_id/brand/type 等）
	hongguoPlaybackDeviceID   = "621699152495976"
	hongguoPlaybackBrand      = "Redmi"
	hongguoPlaybackModel      = "25053RT47C"
	hongguoPlaybackOSVersion  = "16"
	hongguoPlaybackOSAPI      = "36"
	hongguoPlaybackResolution = "1280*2772"
	hongguoPlaybackDPI        = "520"
	hongguoPlaybackChannel    = "update_64"
	hongguoVersionCode        = "71332"
	// 官方客户端 device.json 注册设备（hongguo_v73）
	hongguoMediaDeviceID    = "4016988545905888"
	hongguoMediaInstallID   = "780026313179920"
	hongguoMediaIID         = "780026313179920"
	hongguoMediaCDID        = "4d2a63ef-124e-4417-9d48-173157007e2f"
	hongguoMediaOpenUDID    = "7bbc4f22418b7d81"
	hongguoMediaDeviceToken = "AAASRCFSWTS3QXFLWOI2XZYG345WCLCTTUW6VEQJJGHSYAF3PHLOASXDOQ6LFAAIJHEETKULMSJEU35HZEJV6SBGO3LTRGMN6JX24EX7DAPQJYIJA4OC4OET3BDEY"
	hongguoMediaTtReq       = "1$67cce80fad505dc0efbe77be309f30c6174f0fe6"
	hongguoMediaStoreRegion = "cn-yn"
)

var hongguoSpadeConstants = func() []byte {
	decoded, err := hex.DecodeString("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")
	if err != nil {
		panic("红果 spade 常量无效: " + err.Error())
	}
	return decoded
}()

var hongguoMediaQualityPattern = regexp.MustCompile(`(2160|1440|1080|720|576|540|480|360)`)

type hongguoQueryPair struct {
	key   string
	value string
}

func hongguoQueryEscape(value string) string {
	escaped := url.QueryEscape(value)
	escaped = strings.ReplaceAll(escaped, "+", "%20")
	return strings.ReplaceAll(escaped, "%2A", "*")
}

// hongguoDeviceQuery 构造与官方客户端逐字段一致的取流 query。
//
// 这份字段集是从 exe 真实请求里抓下来的（不是猜的）：
//
//	_rticket ac aid app_name channel device_brand device_id device_platform
//	device_type dpi iid language manifest_version_code os os_api os_version
//	resolution ssmix update_version_code version_code version_name  +  ts（末尾）
//
// 三个易错点：
//  1. 必须带 aid/app_name/version_* 这一整套，少一个就空响应；
//  2. resolution 里的 * 不能转义成 %2A，空格要写成 %20；
//  3. ts 不参与排序，追加在最后。
// hongguoPlaybackDID 返回这次取流应该用的设备号。
//
// 2026-11-07：原实现把 query 的 device_id 与 X-Medusa 一起写死成
// hongguoPlaybackDeviceID（11-04 从 exe 抓到的播放指纹）。实测该指纹已被
// 服务端拒绝（HTTP 200 + 空 body），而同一套身份里的注册 device_id
// （hongguoMediaDeviceID）立刻返回完整 video_model。写死还有第二个后果：
// 设备池轮换、以及「设置 → 播放 → 自定义设备」里用户填的 did，都只改到了
// iid/Cookie，服务端看到的 device_id 始终不变，等于整套兜底机制失效。
func hongguoPlaybackDID(device hongguoDeviceProfile) string {
	if device.DeviceID != "" {
		return device.DeviceID
	}
	return hongguoPlaybackDeviceID
}

func hongguoDeviceQuery(device hongguoDeviceProfile, khronos uint32, ticket uint64) string {
	iid := device.IID
	if iid == "" {
		iid = hongguoMediaIID
	}
	pairs := map[string]string{
		"_rticket":              strconv.FormatUint(ticket, 10),
		"ac":                    "wifi",
		"aid":                   "8662",
		"app_name":              "novelread",
		"channel":               hongguoPlaybackChannel,
		"device_brand":          hongguoPlaybackBrand,
		"device_id":             hongguoPlaybackDID(device),
		"device_platform":       "android",
		"device_type":           hongguoPlaybackModel,
		"dpi":                   hongguoPlaybackDPI,
		"iid":                   iid,
		"language":              "zh",
		"manifest_version_code": hongguoVersionCode,
		"os":                    "android",
		"os_api":                hongguoPlaybackOSAPI,
		"os_version":            hongguoPlaybackOSVersion,
		"resolution":            hongguoPlaybackResolution,
		"ssmix":                 "a",
		"update_version_code":   hongguoVersionCode,
		"version_code":          hongguoVersionCode,
		"version_name":          hongguoMediaVersion,
	}
	keys := make([]string, 0, len(pairs))
	for key := range pairs {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var builder strings.Builder
	for index, key := range keys {
		if index > 0 {
			builder.WriteByte('&')
		}
		builder.WriteString(hongguoQueryEscape(key))
		builder.WriteByte('=')
		builder.WriteString(hongguoQueryEscape(pairs[key]))
	}
	builder.WriteString("&ts=")
	builder.WriteString(strconv.FormatUint(uint64(khronos), 10))
	return builder.String()
}

type hongguoMediaCall struct {
	url     string
	body    []byte
	headers map[string]string
}

func hongguoMediaPayload(videoID string) []byte {
	return []byte(`{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["` + videoID + `"]}}`)
}

func hongguoBuildMediaCall(device hongguoDeviceProfile, host, videoID string) hongguoMediaCall {
	body := hongguoMediaPayload(videoID)
	khronos := uint32(time.Now().Unix())
	baseTicket := uint64(time.Now().UnixMilli())
	var rawURL, query string
	var requestTicket uint64
	// branch 1 的签名变体服务端不认，抖动 _rticket 直到落在其它分支。
	for offset := uint64(0); offset < 32; offset++ {
		requestTicket = baseTicket + offset
		query = hongguoDeviceQuery(device, khronos, requestTicket)
		rawURL = strings.TrimRight(host, "/") + hongguoMultiVideoPath + "?" + query
		if hongguoBranchOf(rawURL, body, khronos) != 1 {
			break
		}
	}
	headers := hongguoSignSuite(device, rawURL, body, khronos, requestTicket)
	// X-Medusa 的设备号输入必须与 query 的 device_id 保持一致。这里只覆盖取流
	// 路径的这一项，不动 hongguoSignSuite（文字接口仍在用它，且当前工作正常）。
	headers["X-Medusa"] = hongguoBuildMedusa(rawURL, body, khronos, hongguoPlaybackDID(device), hongguoMediaVersion)
	return hongguoMediaCall{url: rawURL, body: body, headers: headers}
}

func hongguoMediaModelEntry(result map[string]any, videoID string) (map[string]any, error) {
	data := nestedMap(result, "data")
	if data == nil {
		return nil, errors.New("红果取流接口没有返回数据")
	}
	entry, _ := data[videoID].(map[string]any)
	if entry == nil {
		keys := make([]string, 0, len(data))
		for key := range data {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			if candidate, ok := data[key].(map[string]any); ok {
				entry = candidate
				break
			}
		}
	}
	if entry == nil {
		return nil, errors.New("红果取流接口没有该视频的播放信息")
	}
	if encoded, ok := entry["video_model"].(string); ok {
		var model map[string]any
		decoder := json.NewDecoder(strings.NewReader(encoded))
		decoder.UseNumber()
		if err := decoder.Decode(&model); err != nil {
			return nil, errors.New("红果播放信息格式异常")
		}
		return model, nil
	}
	model, _ := entry["video_model"].(map[string]any)
	if model == nil {
		return nil, errors.New("红果播放信息内容为空")
	}
	return model, nil
}

func hongguoFallbackAddress(model map[string]any) string {
	value := model["fallback_api"]
	switch typed := value.(type) {
	case string:
		trimmed := strings.TrimSpace(typed)
		if strings.HasPrefix(trimmed, "{") {
			var parsed map[string]any
			if json.Unmarshal([]byte(trimmed), &parsed) == nil {
				if nested := mapString(parsed, "fallback_api"); nested != "" {
					return nested
				}
			}
		}
		return trimmed
	case []any:
		if len(typed) > 0 {
			return nativeText(typed[0])
		}
	case map[string]any:
		return mapString(typed, "fallback_api")
	}
	return ""
}

func (d *Downloader) hongguoFallbackInfo(ctx context.Context, device hongguoDeviceProfile, address string) (map[string]any, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	agent := device.UserAgent
	if agent == "" {
		agent = hongguoMediaUserAgent
	}
	request.Header.Set("User-Agent", agent)
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	if cookie := hongguoSignCookie(device, 0); cookie != "" {
		request.Header.Set("Cookie", cookie)
	}
	response, err := d.doPlaybackRequest(request, 10*time.Second)
	if err != nil {
		return nil, err
	}
	content, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	response.Body.Close()
	if readErr != nil {
		return nil, readErr
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("红果清晰度接口 HTTP %d", response.StatusCode)
	}
	var outer map[string]any
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.UseNumber()
	if err := decoder.Decode(&outer); err != nil {
		return nil, errors.New("红果清晰度接口返回格式异常")
	}
	return nestedMap(nestedMap(outer, "video_info"), "data"), nil
}

func hongguoSpadeAddress(value string, seed []byte) (string, error) {
	encoded := strings.TrimSpace(value)
	if encoded == "" {
		return "", nil
	}
	raw, err := hongguoDecodeBase64URLSafe(encoded)
	if err != nil || len(raw) < 5 {
		return "", errors.New("红果 spade 地址密文过短")
	}
	if raw[0] != 0xa8 || raw[2] != 0x01 || raw[3] != 0x00 {
		return "", errors.New("红果 spade 地址头格式错误")
	}
	cipherLength := (len(raw) - 4) / 16 * 16
	if cipherLength == 0 {
		return "", errors.New("红果 spade 地址没有完整密文块")
	}
	first := sha512.Sum512(seed)
	second := sha512.Sum512(append(append([]byte{}, first[:]...), hongguoSpadeConstants...))
	block, err := aes.NewCipher(second[:16])
	if err != nil {
		return "", err
	}
	plaintext := make([]byte, cipherLength)
	cipher.NewCBCDecrypter(block, second[16:32]).CryptBlocks(plaintext, raw[4:4+cipherLength])
	if len(plaintext) > 0 {
		padding := int(plaintext[len(plaintext)-1])
		if padding >= 1 && padding <= 16 && padding <= len(plaintext) {
			plaintext = plaintext[:len(plaintext)-padding]
		}
	}
	for len(plaintext) > 0 && plaintext[len(plaintext)-1] == 0 {
		plaintext = plaintext[:len(plaintext)-1]
	}
	return string(plaintext), nil
}

func hongguoDecodeBase64URLSafe(value string) ([]byte, error) {
	value = strings.TrimSpace(value)
	value = strings.NewReplacer("-", "+", "_", "/").Replace(value)
	if decoded, err := base64.StdEncoding.DecodeString(value); err == nil {
		return decoded, nil
	}
	return base64.RawStdEncoding.DecodeString(value)
}

func hongguoMediaQualityNumber(value string) int {
	text := strings.TrimSpace(value)
	if matched := hongguoMediaQualityPattern.FindString(text); matched != "" {
		number, _ := strconv.Atoi(matched)
		return number
	}
	switch text {
	case "1920":
		return 1080
	case "1280":
		return 720
	case "1024":
		return 576
	case "854":
		return 480
	case "640":
		return 360
	}
	if len(text) >= 3 && len(text) <= 4 {
		if number, err := strconv.Atoi(text); err == nil {
			return number
		}
	}
	return 0
}

func hongguoQualityLabel(value string) string {
	if number := hongguoMediaQualityNumber(value); number > 0 {
		return strconv.Itoa(number) + "P"
	}
	labels := map[string]string{
		"low": "流畅", "smooth": "流畅", "medium": "标清", "normal": "高清",
		"high": "超清", "original": "原画", "uhd": "原画", "super_high": "原画",
	}
	if label, found := labels[strings.ToLower(strings.TrimSpace(value))]; found {
		return label
	}
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return "自动"
	}
	return trimmed
}

type hongguoQualityRow struct {
	key     string
	quality string
	item    map[string]any
}

func hongguoQualityRows(videoList map[string]any) []hongguoQualityRow {
	var rows []hongguoQualityRow
	for key, value := range videoList {
		item, _ := value.(map[string]any)
		if item == nil {
			item = map[string]any{}
		}
		if mapString(item, "main_url") == "" {
			continue
		}
		duplicated := false
		for _, row := range rows {
			if row.key == key {
				duplicated = true
				break
			}
		}
		if duplicated {
			continue
		}
		quality := firstNonEmpty(mapString(item, "quality_desc", "height", "vheight", "quality"), key)
		rows = append(rows, hongguoQualityRow{key: key, quality: quality, item: item})
	}
	sort.SliceStable(rows, func(i, j int) bool {
		left := firstNonEmpty(rows[i].quality, rows[i].key)
		right := firstNonEmpty(rows[j].quality, rows[j].key)
		return hongguoMediaQualityNumber(left) > hongguoMediaQualityNumber(right)
	})
	return rows
}

// hongguoMediaCache 缓存已解析好的播放地址。
//
// playback 接口按设备身份计额度/风控，对同一条 videoID 重复解析是纯浪费：
// 重播、失败重试、预加载都会再打到同一个 videoID。CDN 地址本身有效期较长，
// 这里保守取 8 分钟。
const hongguoMediaCacheTTL = 8 * time.Minute

var hongguoMediaCache = struct {
	sync.Mutex
	items map[string]hongguoMediaCacheEntry
}{items: map[string]hongguoMediaCacheEntry{}}

type hongguoMediaCacheEntry struct {
	media   providerMedia
	expires time.Time
}

func hongguoLoadCachedMedia(videoID string) (providerMedia, bool) {
	hongguoMediaCache.Lock()
	defer hongguoMediaCache.Unlock()
	entry, found := hongguoMediaCache.items[videoID]
	if !found {
		return providerMedia{}, false
	}
	if time.Now().After(entry.expires) {
		delete(hongguoMediaCache.items, videoID)
		return providerMedia{}, false
	}
	return entry.media, true
}

func hongguoStoreCachedMedia(videoID string, media providerMedia) {
	if videoID == "" || media.URL == "" {
		return
	}
	hongguoMediaCache.Lock()
	defer hongguoMediaCache.Unlock()
	if len(hongguoMediaCache.items) >= 128 {
		for key := range hongguoMediaCache.items {
			delete(hongguoMediaCache.items, key)
			break
		}
	}
	hongguoMediaCache.items[videoID] = hongguoMediaCacheEntry{
		media:   media,
		expires: time.Now().Add(hongguoMediaCacheTTL),
	}
}

func (downloader *Downloader) resolveHongguoMultiMedia(ctx context.Context, videoID string) (providerMedia, error) {
	// 先看缓存：同一集的重播、重试、预加载都不该再消耗一次接口额度。
	if cached, found := hongguoLoadCachedMedia(videoID); found {
		return cached, nil
	}
	// 直接走 1.2.20 的多设备多线路签名竞速取真实 CDN 授权流。
	//
	// 注意：H5 公开直取通路（hongguoduanju.com/video/public/<id>/360p.mp4）已被禁用——
	// 它对「前 3 集」返回的是一个 10 秒试播文件（mp4 魔数、Range 探测都能通过），
	// 会被误判为完整出流而短路。实测第 244 集走签名接口能取到完整流，
	// 说明签名接口对包括 1-3 集在内的所有集数都能返回授权完整流。
	// 因此这里一律走签名竞速，不再优先公开通路。
	media, err := downloader.raceHongguoPlayback(ctx, videoID)
	if err != nil {
		return providerMedia{}, err
	}
	hongguoStoreCachedMedia(videoID, media)
	return media, nil
}

// 取流阶段顺带拉取 m3u8：播放时本机流服务直接返回缓存内容，省掉一次远程往返。
// 预取失败不阻断播放，交由播放阶段按既有重试处理。
func (downloader *Downloader) prepareHongguoPlaylist(ctx context.Context, media providerMedia) providerMedia {
	if media.Playlist != "" || !isProviderHTTPMediaURL(media.URL) {
		return media
	}
	parsed, err := url.Parse(media.URL)
	if err != nil || !strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8") {
		return media
	}
	playlist, finalURL, err := downloader.fetchMediaPlaylist(ctx, media.URL, media.Referer)
	if err != nil {
		return media
	}
	if !strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(playlist, "\ufeff")), "#EXTM3U") {
		return media
	}
	media.Playlist = playlist
	media.URL = finalURL
	if duration := m3u8Duration(playlist); duration > 0 {
		media.Duration = duration
	}
	return media
}
