package core

// 红果短剧 H5 公开视频直取。
//
// 2026-11-03 实测（见 TESTREPORT-hgonly-2026-11-03.md）：
//   GET https://hongguoduanju.com/video/public/<mixed_video_id>/360p.mp4
// 无需登录、无需 X-Gorgon / X-Argus / X-Ladon 签名、支持 Range，
// 且对任意剧集都成立——H5 页面只是不给受保护集渲染这个地址，文件本身是公开的。
//
// 因此优先走这条路：省掉整套签名竞速，也不受签名算法未复刻的影响。
// 探测失败时再回落到 provider_hongguo_race.go 里的签名取流，并把失败原因一并带回。

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

const (
	hongguoPublicVideoBase    = "https://hongguoduanju.com/video/public/"
	hongguoPublicVideoQuality = "360p"
	hongguoPublicVideoReferer = "https://hongguoduanju.com/"
)

// mixed_video_id 是纯数字；超范围的输入不值得发请求。
var hongguoPublicVideoIDPattern = regexp.MustCompile(`^[0-9]{10,25}$`)

// 公开视频走独立的普通 HTTP 客户端：不套浏览器指纹传输层，避免 Range/重定向被改写。
var hongguoPublicVideoClient = &http.Client{Timeout: 15 * time.Second}

func hongguoPublicVideoURL(videoID string) string {
	return hongguoPublicVideoBase + url.PathEscape(videoID) + "/" + hongguoPublicVideoQuality + ".mp4"
}

// hongguoPublicMedia 构造公开地址并用 Range 探测，按 MP4 魔数确认后才返回。
func (downloader *Downloader) hongguoPublicMedia(ctx context.Context, videoID string) (providerMedia, error) {
	videoID = strings.TrimSpace(videoID)
	if videoID == "" {
		return providerMedia{}, errors.New("公开视频：videoID 为空")
	}
	if !hongguoPublicVideoIDPattern.MatchString(videoID) {
		return providerMedia{}, fmt.Errorf("公开视频：videoID 形态异常 %q", videoID)
	}
	address := hongguoPublicVideoURL(videoID)

	probeCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(probeCtx, http.MethodGet, address, nil)
	if err != nil {
		return providerMedia{}, err
	}
	request.Header.Set("Range", "bytes=0-63")

	response, err := hongguoPublicVideoClient.Do(request)
	if err != nil {
		return providerMedia{}, fmt.Errorf("公开视频请求失败：%v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		return providerMedia{}, fmt.Errorf("公开视频 HTTP %d（%s）", response.StatusCode, hongguoPublicVideoBase+videoID+"/")
	}

	head, _ := io.ReadAll(io.LimitReader(response.Body, 64))
	if len(head) < 8 || string(head[4:8]) != "ftyp" {
		return providerMedia{}, fmt.Errorf("公开视频不是 MP4（Content-Type=%s，前 8 字节=%x）",
			firstNonEmpty(response.Header.Get("Content-Type"), "空"), head)
	}

	return providerMedia{
		URL:     address,
		Referer: hongguoPublicVideoReferer,
		Quality: hongguoMediaQualityNumber(hongguoPublicVideoQuality),
		Codec:   "h264",
	}, nil
}
