//go:build live

package core

import (
	"strings"
	"testing"
)

// 用 exe 实测的真实取流 URL 回算 branch。
// exe 日志为 "SIGN mode=full branch=2"，若这里也算出 2，说明 Medusa/SM3 派生链路与官方一致；
// 算不出则证明该链路存在偏差。
//
//	go test -tags live ./core/ -run TestCheckBranch -v
func TestCheckBranch(t *testing.T) {
	// 取自 HG_DUMP_SIGN 真实输出
	rawURL := "https://api5-normal-lq.fqnovel.com/novel/player/multi_video_model/v1/?_rticket=1793686560017&ac=wifi&aid=8662&app_name=novelread&channel=update_64&device_brand=Redmi&device_id=3260526922310188&device_platform=android&device_type=25053RT47C&dpi=520&iid=&language=zh&manifest_version_code=71332&os=android&os_api=36&os_version=16&resolution=1280*2772&ssmix=a&update_version_code=71332&version_code=71332&version_name=7.1.3.32&ts=1793686560"

	videoID := "7693569481984969752"
	body := hongguoMediaPayload(videoID)

	// khronos 取自 URL 末尾 ts
	khronos := uint32(1793686560)

	branch := hongguoBranchOf(rawURL, body, khronos)
	t.Logf("exe 日志 branch=2，本项目算法算得 branch=%d", branch)
	if branch == 2 {
		t.Logf("结论：branch 派生一致，Medusa/SM3 链路可信")
	} else {
		t.Logf("结论：branch 不一致，Medusa/SM3 派生链路与官方不同")
	}

	// 同时打印哪些字段被参与
	q := rawURL
	if i := strings.IndexByte(rawURL, '?'); i >= 0 {
		q = rawURL[i+1:]
	}
	t.Logf("参与签名的 query 长度=%d body 长度=%d", len(q), len(body))
}
