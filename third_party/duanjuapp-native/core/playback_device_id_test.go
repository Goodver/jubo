package core

import (
	"strings"
	"testing"
)

// 回归哨兵：取流请求里的 device_id 必须跟着当前身份走。
//
// 2026-11-07 之前，query 的 device_id 与 X-Medusa 都被写死成同一个播放指纹，
// 导致设备池轮换和「设置 → 播放 → 自定义设备」填的 did 全都只改到 iid/Cookie，
// 服务端看到的设备号恒定不变。该指纹失效后整套兜底机制等于不存在。
func TestPlaybackDeviceIDFollowsProfile(t *testing.T) {
	const videoID = "7698761405498936345"
	const khronos = uint32(1794000000)
	const ticket = uint64(1794000000000)

	primary := hongguoDevicePool()[0]
	primaryQuery := hongguoDeviceQuery(primary, khronos, ticket)
	// 池首必须是实测仍可用的旧版注册身份；11-07 上午那套注册 did 已被风控。
	if primary.DeviceID != "1905922028880368" {
		t.Fatalf("池首应为仍可用的旧版注册身份, 实际: %s", primary.DeviceID)
	}
	if !strings.Contains(primaryQuery, "device_id="+primary.DeviceID) {
		t.Fatalf("主身份的 device_id 没有跟随 profile: %s", primaryQuery)
	}
	if strings.Contains(primaryQuery, "device_id="+hongguoPlaybackDeviceID) {
		t.Fatalf("主身份仍在用已失效的写死播放指纹: %s", primaryQuery)
	}

	custom, ok := (hongguoCustomDevice{DID: "1234567890123456"}).profile()
	if !ok {
		t.Fatal("自定义设备没有生成身份")
	}
	customQuery := hongguoDeviceQuery(custom, khronos, ticket)
	if !strings.Contains(customQuery, "device_id=1234567890123456") {
		t.Fatalf("自定义 did 没有进入取流 query: %s", customQuery)
	}

	call := hongguoBuildMediaCall(custom, hongguoPlayHosts[0], videoID)
	if !strings.Contains(call.url, "device_id=1234567890123456") {
		t.Fatalf("取流 URL 没有带上自定义 did: %s", call.url)
	}
	if call.headers["X-Medusa"] == "" {
		t.Fatal("取流请求缺少 X-Medusa")
	}
}

// 用户填了自定义设备时，它必须排在第一轮，而不是第三轮兜底。
func TestCustomDeviceLeadsPlaybackWaves(t *testing.T) {
	plain := &Downloader{}
	plainWaves := plain.hongguoPlaybackWaves()
	if len(plainWaves) == 0 || len(plainWaves[0]) == 0 {
		t.Fatal("没有生成取流竞速轮次")
	}
	if plainWaves[0][0].device.Custom {
		t.Fatal("未配置自定义设备时第一轮不该是 custom")
	}

	filled := &Downloader{playbackDevice: hongguoCustomDevice{DID: "1234567890123456"}}
	filledWaves := filled.hongguoPlaybackWaves()
	if len(filledWaves) == 0 || len(filledWaves[0]) == 0 {
		t.Fatal("没有生成取流竞速轮次")
	}
	if !filledWaves[0][0].device.Custom || filledWaves[0][0].device.DeviceID != "1234567890123456" {
		t.Fatalf("自定义设备没有排在第一轮: %+v", filledWaves[0][0].device)
	}
	// 第二轮是「同一身份换线路」，仍应使用自定义设备。
	if len(filledWaves) > 1 {
		for _, attempt := range filledWaves[1] {
			if !attempt.device.Custom {
				t.Fatalf("第二轮应是同一自定义身份换线路: %s", attempt.label())
			}
		}
	}
	// 第三轮起才换设备身份，此时不能再把自定义设备重复发一遍。
	for _, wave := range filledWaves[2:] {
		for _, attempt := range wave {
			if attempt.device.Custom {
				t.Fatalf("自定义设备在换设备轮被重复发送: %s", attempt.label())
			}
		}
	}
}
