//go:build live

package core

import "testing"

// 只发极少量请求，确认 11-07 上午唯一成功过的「注册设备 did」是否仍可用，
// 以及当前竞速池首身份的状态，避免把身份额度再次打空。
func TestLiveSingleDeviceCheck20261107(t *testing.T) {
	videoID := "7698761405498936345"
	host := "https://api5-normal-lq.fqnovel.com"
	pool := hongguoDevicePool()
	checks := []struct {
		name, did, iid string
	}{
		{"注册设备did", hongguoMediaDeviceID, hongguoMediaIID},
		{"池首身份", pool[0].DeviceID, pool[0].IID},
		{"旧版注册did", "1905922028880368", "1905922028884464"},
		{"11-03探针did", "3260526922310188", "3260526922314284"},
	}
	for _, c := range checks {
		code, length, body := diagPlaybackPost(pool[0], host, videoID, c.did, c.iid)
		if len(body) > 900 {
			body = body[:900]
		}
		t.Logf("%-12s did=%s iid=%s HTTP=%d len=%d body=%s", c.name, c.did, c.iid, code, length, body)
	}
}
