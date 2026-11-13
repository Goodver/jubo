//go:build live

package core

import (
	"context"
	"testing"
	"time"
)

// 用官方 App「基础信息」页里的真实 did + 本机档案取流，验证是否恢复。
//
//	go test -tags live ./core/ -run TestLiveRealDID -v -timeout 180s
func TestLiveRealDID(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	custom := hongguoCustomDevice{
		DID:        "3349573863242644",
		UID:        "",
		Brand:      "xiaomi",
		Model:      "23049RAD8C",
		OSVersion:  "15",
		OSAPI:      "35",
		Resolution: "1080*2400",
		DPI:        "440",
		ABI:        "arm64-v8a",
	}
	d.playbackDevice = custom

	profile, ok := custom.profile()
	if !ok {
		t.Fatal("profile 未生效")
	}
	t.Logf("UA=%s", profile.UserAgent)
	t.Logf("did=%s cdid=%s install=%s", profile.DeviceID, profile.CDID, profile.InstallID)

	vids := []string{
		"7690282289934109720", // 异界降临 ep1（exe 实测 141s）
		"7692004448301747225", // 猎魔人小姐 ep1（exe 实测 138s）
		"7700968020511837208", // 之前当单集 id 用的剧集 id，作对照
	}
	for _, id := range vids {
		start := time.Now()
		media, err := d.resolveHongguoMultiMedia(ctx, id)
		cost := time.Since(start).Milliseconds()
		if err != nil {
			t.Logf("vid=%s 失败 %dms: %v", id, cost, publicError(err))
			continue
		}
		t.Logf("vid=%s 成功 %dms url=%.70s dur=%v", id, cost, media.URL, media.Duration)
	}
}
