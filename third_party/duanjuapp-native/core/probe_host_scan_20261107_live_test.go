//go:build live

package core

import "testing"

// 11-07 实机复测：主接口被静默风控时，逐条线路确认是否有未受限的入口。
// 每个 host 只发一次请求，避免把设备额度继续打空。
func TestLiveHostScan20261107(t *testing.T) {
	videoID := "7698761405498936345"
	primary := hongguoDevicePool()[0]
	for _, host := range hongguoPlayHosts {
		code, length, body := diagPlaybackPost(primary, host, videoID, primary.DeviceID, primary.IID)
		preview := body
		if len(preview) > 120 {
			preview = preview[:120]
		}
		t.Logf("%-46s HTTP=%d len=%d body=%s", host, code, length, preview)
	}
}
