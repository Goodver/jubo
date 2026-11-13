//go:build live

package core

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 明确验证：取流来自「嵌入的 openhongguo 匿名设备引擎」，而不是旧版
// multi_video_model 竞速链路碰巧恢复。判据是调用后 App 数据目录里必须
// 出现一份服务端注册过的匿名设备档案（device_id_str / install_id_str）。
//
//	go test -tags live -run TestLiveOHGResolve -v ./core/ -timeout 120s
func TestLiveOHGResolve(t *testing.T) {
	dir := t.TempDir()
	configureOHGProfile(dir)
	d := &Downloader{}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	media, err := d.resolveOHGMedia(ctx, "7701336636495252504")
	if err != nil {
		t.Fatalf("匿名设备引擎取流失败: %v", err)
	}
	t.Logf("主地址=%s", truncate(media.URL, 100))
	t.Logf("画质=%d 编码=%s 清晰度档数=%d CENC key=%d 字节",
		media.Quality, media.Codec, len(media.Variants), len(media.CENCKey))
	if media.URL == "" || len(media.CENCKey) != 16 {
		t.Fatal("没有拿到可用的媒体地址或内容密钥")
	}

	profile := filepath.Join(dir, "openhongguo-profile.json")
	data, err := os.ReadFile(profile)
	if err != nil {
		t.Fatalf("匿名设备档案没有落盘（说明走的不是新引擎）: %v", err)
	}
	if !bytes.Contains(data, []byte("device_id_str")) || !bytes.Contains(data, []byte("install_id_str")) {
		t.Fatalf("设备档案不含服务端分配的 did/iid: %s", truncate(string(data), 200))
	}
	t.Logf("匿名设备档案已落盘: %s (%d 字节)", profile, len(data))
}
