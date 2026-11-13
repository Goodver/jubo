//go:build live

package core

import (
	"bytes"
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"testing"
	"time"
)

// 11-07 实机：服务端看到的出口是 IPv6，且 GET/POST 都被静默丢空包。
// 对比 IPv4 出口与 HTTP/1.1 协议组合，确认是否只是传输层策略差异。
func TestLiveTransportMatrix20261107(t *testing.T) {
	videoID := "7698761405498936345"
	primary := hongguoDevicePool()[0]
	call := hongguoBuildMediaCall(primary, hongguoPlayHosts[0], videoID)

	dial4 := func(ctx context.Context, network, addr string) (net.Conn, error) {
		return (&net.Dialer{Timeout: 8 * time.Second}).DialContext(ctx, "tcp4", addr)
	}
	clients := []struct {
		name   string
		client *http.Client
	}{
		{"默认(h2/IPv6)", &http.Client{Timeout: 12 * time.Second}},
		{"IPv4+h2", &http.Client{Timeout: 12 * time.Second, Transport: &http.Transport{
			ForceAttemptHTTP2: true, DialContext: dial4,
		}}},
		{"HTTP1.1/IPv6", &http.Client{Timeout: 12 * time.Second, Transport: &http.Transport{
			TLSClientConfig: &tls.Config{NextProtos: []string{"http/1.1"}},
		}}},
		{"HTTP1.1+IPv4", &http.Client{Timeout: 12 * time.Second, Transport: &http.Transport{
			DialContext: dial4, TLSClientConfig: &tls.Config{NextProtos: []string{"http/1.1"}},
		}}},
	}
	for _, c := range clients {
		request, err := http.NewRequest(http.MethodPost, call.url, bytes.NewReader(call.body))
		if err != nil {
			t.Fatal(err)
		}
		for name, value := range call.headers {
			request.Header.Set(name, value)
		}
		response, err := c.client.Do(request)
		if err != nil {
			t.Logf("%-16s ERR %v", c.name, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(response.Body, 256))
		response.Body.Close()
		t.Logf("%-16s HTTP=%d proto=%s len=%d remoteIp=%s body=%q", c.name,
			response.StatusCode, response.Proto, len(content),
			response.Header.Get("X-Request-Ip"), string(content))
		time.Sleep(250 * time.Millisecond)
	}
}
