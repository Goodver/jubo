//go:build live

package core

import (
	"context"
	"net/http"
	"testing"
	"time"
)

// 验证 H5 公开视频直取：不走签名、不需要登录，任意剧集都应能拿到 360p MP4。
//
//	go test -tags live ./core/ -run TestPublicVideoDirect -v
func TestPublicVideoDirect(t *testing.T) {
	downloader := &Downloader{client: &http.Client{Timeout: 20 * time.Second}}
	ids := []string{
		"7683595760918596632", // app 详情接口返回的 mixed_video_id
		"7701336636495252504", // H5 首页公开的第 1 集
		"7701336720221932568", // H5 第 2 集（页面不渲染地址，但文件存在）
		"7701336729264868376", // H5 第 3 集
	}
	for _, id := range ids {
		media, err := downloader.hongguoPublicMedia(context.Background(), id)
		if err != nil {
			t.Errorf("%-20s 失败: %v", id, err)
			continue
		}
		t.Logf("%-20s OK quality=%d codec=%s url=%s", id, media.Quality, media.Codec, media.URL)
	}
}
