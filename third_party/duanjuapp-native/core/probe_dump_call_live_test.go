//go:build live

package core

import (
	"sort"
	"testing"
)

// 打印项目实际生成的取流请求（不发送），用于与 exe 的真实请求逐字段对照。
//
//	go test -tags live ./core/ -run TestDumpBuiltCall -v
func TestDumpBuiltCall(t *testing.T) {
	device := hongguoDevicePool()[0]
	call := hongguoBuildMediaCall(device, "https://api5-normal-lq.fqnovel.com", "7693569481984969752")

	t.Logf("URL: %s", call.url)
	t.Logf("BODY: %s", string(call.body))

	keys := make([]string, 0, len(call.headers))
	for k := range call.headers {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		v := call.headers[k]
		if len(v) > 80 {
			v = v[:80] + "..."
		}
		t.Logf("H %-26s = %s", k, v)
	}
	t.Logf("设备: id=%s brand=%s model=%s ver=%s api=%s res=%s dpi=%s channel=%s token=%v",
		device.DeviceID, device.Brand, device.Model, device.OSVersion, device.OSAPI,
		device.Resolution, device.DPI, device.Channel, device.TokenBound)
}
