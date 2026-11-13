//go:build live

package core

import (
	"context"
	"testing"
	"time"
)

// 用桌面端 exe 当前实际在用的身份组（device:spares[2] / [1]）取流，验证
// 「身份组是否完整（device_id/install_id/cdid/openudid/token/ttreq 各自独立）」
// 是不是被拒的关键。
//
//	go test -tags live ./core/ -run TestLiveExeIdentities -v -timeout 240s
func TestLiveExeIdentities(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()

	sets := []hongguoDeviceProfile{
		{
			Name: "exe_spare2", Brand: "xiaomi", Model: "23127PN0CC",
			OSVersion: "14", OSAPI: "34", Resolution: "1200*2670", DPI: "460",
			Channel: "xiaomi_8662_64", UserAgent: hongguoMediaUserAgent, HostABI: "arm64-v8a",
			DeviceID: "1905928731624264", InstallID: "1905928731628360", IID: "1905928731628360",
			CDID: "729065d8-7d47-4edf-89ed-719409e672f2", OpenUDID: "72bb1287b5eebf5e",
			DeviceToken: "AAAXT67YNY32QDA2TZZHMG22XCB63YLBQ32TWMMWPQ5DNFOKCZBTJPOKXXTCTNDRXH3USAXDXTJXMMUYJFZGQ37FJB2TQRWQFLCAH3VGK5LNITI3L4UWQ37OXVFRC",
			TtReq:       "1$79d3f6b09bb3bfc5f9bfbe95c5acf8194c559e7c",
			StoreRegion: "cn-yn", TokenBound: true,
		},
		{
			Name: "exe_spare1", Brand: "xiaomi", Model: "23127PN0CC",
			OSVersion: "14", OSAPI: "34", Resolution: "1200*2670", DPI: "460",
			Channel: "xiaomi_8662_64", UserAgent: hongguoMediaUserAgent, HostABI: "arm64-v8a",
			DeviceID: "428185093163495", InstallID: "428185093167591", IID: "428185093167591",
			CDID: "7726c860-3adf-4cc5-af96-5d1955a23fca", OpenUDID: "93f0bc9510036862",
			DeviceToken: "AAA2SE5B2ITD7QY53FHVJP2RHDBBWXD6UUZLXNUVQO2YBAZIF2RELPVBAFWV3KLGPR4VYA6H2OVF2FSHDQQCUKUGCIK6UKHXFQ4A",
			TtReq:       "1$435937133d1f3ef8afb99ea8ea686f3d45d3af58",
			StoreRegion: "cn-yn", TokenBound: true,
		},
		{
			Name: "exe_spare0", Brand: "xiaomi", Model: "23127PN0CC",
			OSVersion: "14", OSAPI: "34", Resolution: "1200*2670", DPI: "460",
			Channel: "xiaomi_8662_64", UserAgent: hongguoMediaUserAgent, HostABI: "arm64-v8a",
			DeviceID: "3260526922310188", InstallID: "3260526922314284", IID: "3260526922314284",
			CDID: "9eae5c12-6b55-45a0-8d67-ef76452f7a06", OpenUDID: "c1e48036f673edff",
			DeviceToken: "AAAXB45MKYYIJTVI7XZVZQLLSGEKPZMPBHJ6JW54PDHWNP22DDSOLQFUMXU3UDJWDIM57H7HRBRP3IJW2QKAFBY3KZZBJCLULXUMEDXHVINGGFGYIPILHNCXQ24GA",
			TtReq:       "1$cacda3a3394d9210170d652c93ba610c272a73bf",
			StoreRegion: "cn-yn", TokenBound: true,
		},
	}

	vid := "7700968020511837208" // 学法律的玄学大师 第二季 ep1
	for _, set := range sets {
		d.playbackDevice = hongguoCustomDevice{}
		start := time.Now()
		media, err := d.hongguoFetchMedia(ctx, vid, hongguoPlayAttempt{device: set, host: hongguoPlayHosts[0]})
		cost := time.Since(start).Milliseconds()
		if err != nil {
			t.Logf("%-12s 失败 %dms: %v", set.Name, cost, publicError(err))
			continue
		}
		t.Logf("%-12s 成功 %dms url=%.65s dur=%v", set.Name, cost, media.URL, media.Duration)
	}
}
