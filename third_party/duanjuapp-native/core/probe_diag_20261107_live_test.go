//go:build live

package core

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

// 2026-11-07 取流失效诊断。
//
// 背景：生产路径 hongguoDeviceQuery 把 query 里的 device_id 写死成
// hongguoPlaybackDeviceID，X-Medusa 也用同一个常量，因此「设备池轮换」和
// 「设置里填自定义 did」并没有真正改变服务端看到的设备号。本探针复刻同一份
// query，只把 device_id / iid 换成候选值并同步重算签名，用来区分：
//
//   - 只有这一个播放指纹被收紧（换 did 能出流 → 换身份即可修复）
//   - 整个 /novel/player/* 收紧（所有 did 都空 → 需要会话/登录态等新机制）
//
// 运行：go test -tags live ./core/ -run TestLiveDiagPlayback20261107 -v -timeout 240s
func diagQueryWithIdentity(device hongguoDeviceProfile, khronos uint32, ticket uint64, did, iid string) string {
	if iid == "" {
		iid = hongguoMediaIID
	}
	pairs := map[string]string{
		"_rticket":              strconv.FormatUint(ticket, 10),
		"ac":                    "wifi",
		"aid":                   "8662",
		"app_name":              "novelread",
		"channel":               hongguoPlaybackChannel,
		"device_brand":          hongguoPlaybackBrand,
		"device_id":             did,
		"device_platform":       "android",
		"device_type":           hongguoPlaybackModel,
		"dpi":                   hongguoPlaybackDPI,
		"iid":                   iid,
		"language":              "zh",
		"manifest_version_code": hongguoVersionCode,
		"os":                    "android",
		"os_api":                hongguoPlaybackOSAPI,
		"os_version":            hongguoPlaybackOSVersion,
		"resolution":            hongguoPlaybackResolution,
		"ssmix":                 "a",
		"update_version_code":   hongguoVersionCode,
		"version_code":          hongguoVersionCode,
		"version_name":          hongguoMediaVersion,
	}
	keys := make([]string, 0, len(pairs))
	for key := range pairs {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var builder strings.Builder
	for index, key := range keys {
		if index > 0 {
			builder.WriteByte('&')
		}
		builder.WriteString(hongguoQueryEscape(key))
		builder.WriteByte('=')
		builder.WriteString(hongguoQueryEscape(pairs[key]))
	}
	builder.WriteString("&ts=")
	builder.WriteString(strconv.FormatUint(uint64(khronos), 10))
	return builder.String()
}

func diagPlaybackPost(device hongguoDeviceProfile, host, videoID, did, iid string) (int, int, string) {
	identity := device
	identity.DeviceID = did
	identity.InstallID = iid
	identity.IID = iid

	body := hongguoMediaPayload(videoID)
	khronos := uint32(time.Now().Unix())
	ticket := uint64(time.Now().UnixMilli())
	query := diagQueryWithIdentity(identity, khronos, ticket, did, iid)
	rawURL := strings.TrimRight(host, "/") + hongguoMultiVideoPath + "?" + query
	headers := hongguoSignSuite(identity, rawURL, body, khronos, ticket)
	headers["X-Medusa"] = hongguoBuildMedusa(rawURL, body, khronos, did, hongguoMediaVersion)

	request, err := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
	if err != nil {
		return 0, 0, err.Error()
	}
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	client := &http.Client{Timeout: 12 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return 0, 0, err.Error()
	}
	defer response.Body.Close()
	content, _ := io.ReadAll(io.LimitReader(response.Body, 512))
	return response.StatusCode, len(content), string(content)
}

func TestLiveDiagPlayback20261107(t *testing.T) {
	videoID := "7698761405498936345"
	primary := hongguoDevicePool()[0]
	pool := hongguoDevicePool()

	candidates := []struct {
		name, did, iid string
	}{
		{"当前播放指纹(基线)", hongguoPlaybackDeviceID, hongguoMediaIID},
		{"注册设备did", hongguoMediaDeviceID, hongguoMediaIID},
		{"11-03探针did", "3260526922310188", "3260526922314284"},
		{"池内xiaomi_13", pool[1].DeviceID, pool[1].InstallID},
		{"池内samsung_s24u", pool[7].DeviceID, pool[7].InstallID},
		{"基线did+随机iid", hongguoPlaybackDeviceID, hongguoStableDeviceID("diag-iid", 1)},
		{"全新随机did", hongguoStableDeviceID("diag-did", 1), hongguoStableDeviceID("diag-did", 2)},
		{"相邻did", "621699152495977", hongguoMediaIID},
	}

	t.Log("=== A. 换设备身份（固定线路 host[0]）===")
	for _, candidate := range candidates {
		status, length, body := diagPlaybackPost(primary, hongguoPlayHosts[0], videoID, candidate.did, candidate.iid)
		preview := strings.ReplaceAll(body, "\n", " ")
		if len(preview) > 110 {
			preview = preview[:110] + "…"
		}
		tag := ""
		if length > 0 {
			tag = "  <== 有数据!"
		}
		t.Logf("%-20s did=%-20s HTTP=%d len=%d%s %s", candidate.name, candidate.did, status, length, tag, preview)
		time.Sleep(300 * time.Millisecond)
	}

	t.Log("=== B. 换线路（固定基线身份）===")
	for _, host := range hongguoPlayHosts {
		status, length, body := diagPlaybackPost(primary, host, videoID, hongguoPlaybackDeviceID, hongguoMediaIID)
		preview := strings.ReplaceAll(body, "\n", " ")
		if len(preview) > 80 {
			preview = preview[:80] + "…"
		}
		tag := ""
		if length > 0 {
			tag = "  <== 有数据!"
		}
		t.Logf("%-46s HTTP=%d len=%d%s %s", host, status, length, tag, preview)
		time.Sleep(250 * time.Millisecond)
	}

	t.Log("=== C. 对照：文字接口是否仍正常 ===")
	appReq := fmt.Sprintf("https://api5-normal-lq.fqnovel.com/novel/player/video_detail/v1/?device_id=%s&iid=%s", hongguoMediaDeviceID, hongguoMediaInstallID)
	t.Logf("文字接口样本 URL（仅作对照，不发起请求）: %.120s", appReq)
}
