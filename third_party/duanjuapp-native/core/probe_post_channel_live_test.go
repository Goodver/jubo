//go:build live

package core

import (
	"bytes"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

// 判定 POST 是否被整体拦截：对多个非取流 POST 接口做无签名请求，
// 若其它 POST 正常返回，说明限制只针对取流接口（则问题在 body/签名）；
// 若全部空，说明 POST 通道整体被风控。
//
//	go test -tags live ./core/ -run TestLivePostChannel -v -timeout 150s
func TestLivePostChannel(t *testing.T) {
	host := "https://api5-normal-lq.fqnovel.com"
	device := hongguoDevicePool()[0]

	baseQuery := func(extra ...[2]string) string {
		khronos := time.Now().Unix()
		rticket := time.Now().UnixMilli()
		pairs := [][2]string{
			{"ac", "wifi"}, {"aid", "8662"}, {"app_name", "novelread"},
			{"channel", "xiaomi_8662_64"}, {"cdid", "4d2a63ef-124e-4417-9d48-173157007e2f"},
			{"device_brand", "xiaomi"}, {"device_id", "4016988545905888"},
			{"device_platform", "android"}, {"device_type", "23127PN0CC"},
			{"dpi", "460"}, {"iid", "780026313179920"}, {"language", "zh"},
			{"manifest_version_code", "73932"}, {"os", "android"},
			{"os_api", "34"}, {"os_version", "14"}, {"resolution", "1200*2670"},
			{"ssmix", "a"}, {"update_version_code", "73932"},
			{"version_code", "73932"}, {"version_name", "7.3.9.32"},
		}
		var b strings.Builder
		b.WriteString("_rticket=" + strconv.FormatInt(rticket, 10))
		for _, kv := range pairs {
			b.WriteString("&" + kv[0] + "=" + hongguoQueryEscape(kv[1]))
		}
		for _, kv := range extra {
			b.WriteString("&" + kv[0] + "=" + hongguoQueryEscape(kv[1]))
		}
		b.WriteString("&ts=" + strconv.FormatInt(khronos, 10))
		return b.String()
	}

	cases := []struct {
		name   string
		method string
		path   string
		extra  [][2]string
		body   string
	}{
		{"POST-cell/change", "POST", "/reading/bookapi/bookmall/cell/change/v",
			[][2]string{{"category_id", "0"}, {"cell_id", "7294257141911650341"}, {"change_type", "0"}}, `{}`},
		{"POST-read_progress", "POST", "/reading/bookapi/read_progress/upload/v", nil,
			`{"series_id":"7695672348837432344","vid":"7670376722964941848","progress":10}`},
		{"GET-bookmall/tab", "GET", "/reading/bookapi/bookmall/tab/v",
			[][2]string{{"tab_type", "16"}, {"tab_index", "0"}}, ""},
	}

	for _, c := range cases {
		rawURL := host + c.path + "?" + baseQuery(c.extra...)
		var bodyReader io.Reader
		if c.body != "" {
			bodyReader = bytes.NewReader([]byte(c.body))
		}
		req, _ := http.NewRequest(c.method, rawURL, bodyReader)
		req.Header.Set("User-Agent", device.UserAgent)
		req.Header.Set("Accept", hongguoAcceptHeader)
		if c.body != "" {
			req.Header.Set("Content-Type", hongguoMediaContentType)
		}

		client := &http.Client{Timeout: 15 * time.Second}
		resp, err := client.Do(req)
		if err != nil {
			t.Logf("%-22s ERR %v", c.name, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		resp.Body.Close()
		mark := " [空]"
		if len(content) > 0 {
			mark = " [有数据]"
		}
		t.Logf("%-22s %s HTTP=%d len=%d%s", c.name, c.method, resp.StatusCode, len(content), mark)
		if len(content) > 0 {
			p := string(content)
			if len(p) > 160 {
				p = p[:160]
			}
			t.Logf("     %s", p)
		}
		time.Sleep(250 * time.Millisecond)
	}
}
