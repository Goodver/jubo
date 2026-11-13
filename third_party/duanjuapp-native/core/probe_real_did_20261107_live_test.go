//go:build live

package core

import "testing"

// 11-07 实机：从红果「基础信息」调试面板读到的本机真实 device_id。
// 只发极少量请求，确认它与哪种 iid 组合还能拿到 video_model，
// 避免把用户手机红果自己正在用的设备额度打空。
func TestLiveRealDeviceID20261107(t *testing.T) {
	videoID := "7698761405498936345"
	did := "3349573863242644"
	primary := hongguoDevicePool()[0]
	checks := []struct {
		name, iid string
	}{
		{"did+4096", "3349573863246740"},
		{"did自身", did},
		{"默认iid", hongguoMediaIID},
	}
	for _, c := range checks {
		code, length, body := diagPlaybackPost(primary, hongguoPlayHosts[0], videoID, did, c.iid)
		preview := body
		if len(preview) > 220 {
			preview = preview[:220]
		}
		t.Logf("%-10s did=%s iid=%s HTTP=%d len=%d body=%s", c.name, did, c.iid, code, length, preview)
	}
}
