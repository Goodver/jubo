//go:build live

package core

import (
	"fmt"
	"crypto/md5"
	"encoding/hex"
	"io"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"
)

// 请求 URL 字节完全不变，只改变「参与签名的字符串」，定位服务端的规范化规则。
//
//	go test -tags live ./core/ -run TestLiveSignInput -v -timeout 120s
func TestLiveSignInput(t *testing.T) {
	content := ""
	for _, path := range []string{`F:\hongguodesk\hgg.log`, `F:\hongguodesk\hgdump.log`} {
		if raw, err := os.ReadFile(path); err == nil && len(raw) > 0 {
			content = string(raw)
			break
		}
	}
	if content == "" {
		t.Skip("没有 dump 日志")
	}

	reTab := regexp.MustCompile(`url=(https://\S+bookmall/tab/v\S*)`)
	rePlay := regexp.MustCompile(`url=(https://\S+novel/player/multi_video_model/v1/\S*)`)

	targets := []struct {
		name string
		url  string
	}{
		{"目录tab", lastMatch(reTab, content)},
		{"播放multi", lastMatch(rePlay, content)},
	}

	reTS := regexp.MustCompile(`([?&]ts=)\d+`)
	reTicket := regexp.MustCompile(`([?&]_rticket=)\d+`)

	client := &http.Client{Timeout: 15 * time.Second}
	device := hongguoDevicePool()[0]

	for _, target := range targets {
		if target.url == "" {
			continue
		}
		now := time.Now()
		rawURL := reTS.ReplaceAllString(target.url, "${1}"+fmt.Sprintf("%d", now.Unix()))
		rawURL = reTicket.ReplaceAllString(rawURL, "${1}"+fmt.Sprintf("%d", now.UnixMilli()))
		query := hongguoRawQuery(rawURL)
		khronos := uint32(now.Unix())
		ticket := uint64(now.UnixMilli())

		path := ""
		if idx := strings.Index(rawURL, "://"); idx > 0 {
			rest := rawURL[idx+3:]
			if slash := strings.IndexByte(rest, '/'); slash > 0 {
				host := rest[:slash]
				path = rest[slash:]
				_ = host
			}
		}
		pathOnly := path
		if idx := strings.IndexByte(pathOnly, '?'); idx > 0 {
			pathOnly = pathOnly[:idx]
		}
		variants := map[string]string{
			"A-全量(含ts,末位)":       query,
			"B-去掉ts":             stripParam(query, "ts"),
			"E-按字母序重排(ts归位)":     sortedQuery(query),
			"G-问号开头+query":        "?" + query,
			"H-path?query":        pathOnly + "?" + query,
			"I-完整URL":             rawURL,
			"J-path+query(无问号)":    pathOnly + query,
		}

		isPlay := strings.Contains(target.url, "multi_video_model")
		var body []byte
		if isPlay {
			body = []byte(`{"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024},"mixed_video_id_map":{"1004":["7691759547454606361"]}}`)
		}

		names := make([]string, 0, len(variants))
		for name := range variants {
			names = append(names, name)
		}
		sort.Strings(names)

		for _, name := range names {
			signInput := variants[name]
			random := hongguoRandom32() % 65536
			headers := map[string]string{
				"User-Agent":      device.UserAgent,
				"X-Khronos":       fmt.Sprintf("%d", khronos),
				"X-SS-Req-Ticket": fmt.Sprintf("%d", ticket),
				"X-Gorgon":        hongguoXGorgon(signInput, body, khronos, random),
				"X-Helios":        hongguoHelios(khronos),
			}
			method := http.MethodGet
			var reader io.Reader
			if isPlay {
				method = http.MethodPost
				reader = strings.NewReader(string(body))
				headers["Content-Type"] = hongguoMediaContentType
				headers["X-SS-Stub"] = upperMD5(body)
			}
			request, err := http.NewRequest(method, rawURL, reader)
			if err != nil {
				continue
			}
			for k, v := range headers {
				request.Header.Set(k, v)
			}
			response, err := client.Do(request)
			if err != nil {
				t.Logf("%s %-22s 请求失败 %v", target.name, name, err)
				continue
			}
			payload, _ := io.ReadAll(io.LimitReader(response.Body, 2048))
			response.Body.Close()
			t.Logf("%s %-22s status=%d len=%d %s", target.name, name, response.StatusCode, len(payload), preview(payload))
		}
	}
}

func lastMatch(re *regexp.Regexp, text string) string {
	all := re.FindAllStringSubmatch(text, -1)
	if len(all) == 0 {
		return ""
	}
	return all[len(all)-1][1]
}

func stripParam(query, key string) string {
	parts := strings.Split(query, "&")
	out := parts[:0]
	for _, part := range parts {
		if strings.HasPrefix(part, key+"=") {
			continue
		}
		out = append(out, part)
	}
	return strings.Join(out, "&")
}

func sortedQuery(query string) string {
	parts := strings.Split(query, "&")
	sort.Strings(parts)
	return strings.Join(parts, "&")
}

func upperMD5(b []byte) string {
	sum := md5.Sum(b)
	return strings.ToUpper(hex.EncodeToString(sum[:]))
}

func preview(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 160 {
		s = s[:160]
	}
	return s
}
