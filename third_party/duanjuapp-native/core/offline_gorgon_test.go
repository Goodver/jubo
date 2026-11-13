package core

import (
	"strings"
	"testing"
)

// 离线对拍：用 exe 真实发出的 (query, body, khronos, X-Gorgon) 校验 hongguoXGorgon。
//
// 样本取自真实客户端抓包（http2debug 全量日志的第 0 条取流请求）：
//
//	query  : 见下方 rec0Query（21 个字段，ts 在最后）
//	body   : 见下方 rec0Body（259 字节，MD5 = B34B810D8677389C818D73EF1E756B1C，与 X-SS-Stub 一致）
//	khronos: 1793773385
//	随机数 : 从 X-Gorgon 前缀 8404 c58a 4001 反推 → 0x8ac5
//
// 这个用例是 RC4 修正的回归哨兵：一旦 hongguoRC4Gorgon 再被改坏，这里立刻红。
// 不联网、不依赖外部文件，`go test ./core/` 就会跑。
const (
	rec0Query = "_rticket=1793773385007&ac=wifi&aid=8662&app_name=novelread&channel=update_64" +
		"&device_brand=Redmi&device_id=621699152495976&device_platform=android&device_type=25053RT47C" +
		"&dpi=520&iid=780026313179920&language=zh&manifest_version_code=71332&os=android&os_api=36" +
		"&os_version=16&resolution=1280*2772&ssmix=a&update_version_code=71332&version_code=71332" +
		"&version_name=7.1.3.32&ts=1793773385"

	rec0Body = `{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,` +
		`"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,` +
		`"use_server_dns":false,"video_platform":1024},` +
		`"mixed_video_id_map":{"1004":["7686525480618429465"]}}`

	rec0Gorgon = "8404c58a400199fbaa2e6c2571615e946fd846eb0765253226b4"
)

func TestOfflineGorgon(t *testing.T) {
	query := strings.TrimSpace(rec0Query)
	body := []byte(strings.TrimSpace(rec0Body))

	if got := len(body); got != 259 {
		t.Fatalf("样本 body 长度应为 259，实际 %d", got)
	}
	got := hongguoXGorgon(query, body, 1793773385, 0x8ac5)
	t.Logf("want=%s", rec0Gorgon)
	t.Logf("got =%s", got)
	if got != rec0Gorgon {
		t.Fatalf("Gorgon 不一致：RC4 或前缀构造被改坏了")
	}
}
