//go:build live

package core

import (
	"fmt"
	"crypto/tls"
	"io"
	"os"
	"net/http"
	"regexp"
	"strings"
	"testing"
	"time"
)

// 用工程签名器重放 exe 的目录请求（minimal 模式），判断基础签名链是否可用。
//
//	go test -tags live ./core/ -run TestLiveTabReplay -v -timeout 120s
func TestLiveTabReplay(t *testing.T) {
	reURL := regexp.MustCompile(`url=(https://\S+bookmall/tab/v\S*)`)
	reTS := regexp.MustCompile(`([?&]ts=)\d+`)
	reTicket := regexp.MustCompile(`([?&]_rticket=)\d+`)

	content := ""
	for _, path := range []string{`F:\hongguodesk\hgg.log`, `F:\hongguodesk\hgdump.log`} {
		if raw, err := os.ReadFile(path); err == nil && len(raw) > 0 {
			content = string(raw)
			break
		}
	}
	if content == "" {
		t.Skip("没有可用的 dump 日志")
	}
	matches := reURL.FindAllStringSubmatch(content, -1)
	if len(matches) == 0 {
		t.Skip("日志里没有目录请求")
	}
	rawURL := matches[len(matches)-1][1]
	now := time.Now()
	rawURL = reTS.ReplaceAllString(rawURL, "${1}"+fmt.Sprintf("%d", now.Unix()))
	rawURL = reTicket.ReplaceAllString(rawURL, "${1}"+fmt.Sprintf("%d", now.UnixMilli()))
	t.Logf("目标 URL 长度 %d", len(rawURL))

	device := hongguoDevicePool()[0]
	query := hongguoRawQuery(rawURL)
	khronos := uint32(now.Unix())
	ticket := uint64(now.UnixMilli())
	random := hongguoRandom32() % 65536

	cases := []struct {
		label   string
		headers map[string]string
	}{
		{"A-仅Gorgon", map[string]string{
			"User-Agent":      device.UserAgent,
			"X-Khronos":       fmt.Sprintf("%d", khronos),
			"X-SS-Req-Ticket": fmt.Sprintf("%d", ticket),
			"X-Gorgon":        hongguoXGorgon(query, nil, khronos, random),
		}},
		{"B-完整套件", hongguoSignSuite(device, rawURL, nil, khronos, ticket)},
	}

	client := &http.Client{Timeout: 15 * time.Second}
	h1 := &http.Client{
		Timeout: 15 * time.Second,
		Transport: &http.Transport{
			ForceAttemptHTTP2:   false,
			TLSClientConfig:     &tls.Config{NextProtos: []string{"http/1.1"}},
			MaxIdleConnsPerHost: 2,
		},
	}
	for _, item := range cases {
		request, err := http.NewRequest(http.MethodGet, rawURL, nil)
		if err != nil {
			t.Fatal(err)
		}
		for name, value := range item.headers {
			request.Header.Set(name, value)
		}
		response, err := client.Do(request)
		if err != nil {
			t.Logf("%s 请求失败: %v", item.label, err)
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		response.Body.Close()
		head := string(body)
		if len(head) > 260 {
			head = head[:260]
		}
		t.Logf("%s -> status=%d proto=%s len=%d origin=%s\n    %s",
			item.label, response.StatusCode, response.Proto, len(body),
			response.Header.Get("X-Dsa-Origin-Status"), strings.TrimSpace(head))

		request2, _ := http.NewRequest(http.MethodGet, rawURL, nil)
		for name, value := range item.headers {
			request2.Header.Set(name, value)
		}
		response2, err := h1.Do(request2)
		if err != nil {
			t.Logf("%s[H1] 请求失败: %v", item.label, err)
			continue
		}
		body2, _ := io.ReadAll(io.LimitReader(response2.Body, 4096))
		response2.Body.Close()
		head2 := string(body2)
		if len(head2) > 260 {
			head2 = head2[:260]
		}
		t.Logf("%s[H1] -> status=%d proto=%s len=%d\n    %s",
			item.label, response2.StatusCode, response2.Proto, len(body2), strings.TrimSpace(head2))
	}
}
