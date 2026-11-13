package core

import (
	"strings"
	"testing"
)

// TestCustomProfileUsesLocalDevice 确认「读取本机 ID」保存的机型档案
// 真的会覆盖进签名用的设备身份，而不是只换了个 did。
func TestCustomProfileUsesLocalDevice(t *testing.T) {
	device := hongguoCustomDevice{
		DID:        "7123456789012345678",
		Brand:      "xiaomi",
		Model:      "23049RAD8C",
		OSVersion:  "15",
		OSAPI:      "35",
		Resolution: "1220*2712",
		DPI:        "440",
		ABI:        "arm64-v8a",
	}
	profile, ok := device.profile()
	if !ok {
		t.Fatal("配置了 did 但 profile 返回 false")
	}
	if profile.DeviceID != device.DID {
		t.Fatalf("did 没生效: %s", profile.DeviceID)
	}
	if profile.Model != "23049RAD8C" {
		t.Fatalf("机型没生效: %s", profile.Model)
	}
	if profile.OSVersion != "15" || profile.OSAPI != "35" {
		t.Fatalf("系统版本没生效: %s / %s", profile.OSVersion, profile.OSAPI)
	}
	if profile.Resolution != "1220*2712" || profile.DPI != "440" {
		t.Fatalf("屏幕参数没生效: %s / %s", profile.Resolution, profile.DPI)
	}
	if !strings.Contains(profile.UserAgent, "23049RAD8C") {
		t.Fatalf("UA 没跟着换: %s", profile.UserAgent)
	}
	if !strings.Contains(profile.UserAgent, "Android 15") {
		t.Fatalf("UA 里的系统版本没换: %s", profile.UserAgent)
	}
	if profile.TokenBound || profile.DeviceToken != "" || profile.TtReq != "" {
		t.Fatal("自定义设备不该带 device_token/ttreq")
	}
	t.Logf("UA = %s", profile.UserAgent)
}

// TestCustomProfileKeepsDefaults 只填 did 时，机型应该沿用主设备，而不是变成空值。
func TestCustomProfileKeepsDefaults(t *testing.T) {
	profile, ok := (hongguoCustomDevice{DID: "7123456789012345678"}).profile()
	if !ok {
		t.Fatal("profile 返回 false")
	}
	base := hongguoDevicePool()[0]
	if profile.Model != base.Model {
		t.Fatalf("机型应为默认 %s，实际 %s", base.Model, profile.Model)
	}
	if profile.UserAgent != base.UserAgent {
		t.Fatalf("UA 不该变: %s", profile.UserAgent)
	}
}
