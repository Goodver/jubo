package core

import (
	"encoding/base64"
	"encoding/binary"
	"testing"
)

// 用 h2 日志里 exe 实际发出的 X-Helios 对拍 hongguoHeliosWith。
// 每条都能从密文前 4 字节反推出随机数，因此可以完全离线复算。
func TestOfflineHelios(t *testing.T) {
	cases := []struct {
		value   string
		khronos uint32
	}{
		{"suLYqjauU3+U65gV2r2ORFuW60zaybbe+DC18dPZwYXs5uQZ", 1793773385},
		{"5HUV3WRsAoCstdoD49mo+DPIrBCqJRfht8pJ6GK3LlPsh+1L", 1793773386},
		{"SxIyyYpW1b7T3e6+2p6N6h0A2//BylxgfCIKDMpWGfjupy7i", 1793773386},
		{"HQZkQLC9kJNKlaLhHYITdh9/Dtmo28vciBZBK/iZstm5r0Ws", 1793773387},
	}
	for _, c := range cases {
		want, err := base64.StdEncoding.DecodeString(c.value)
		if err != nil {
			t.Fatalf("解码失败: %v", err)
		}
		random := binary.LittleEndian.Uint32(want[:4])
		got := hongguoHeliosWith(c.khronos, random)
		if got != c.value {
			t.Errorf("khronos=%d 不一致\n want=%s\n got =%s", c.khronos, c.value, got)
		}
	}
}
