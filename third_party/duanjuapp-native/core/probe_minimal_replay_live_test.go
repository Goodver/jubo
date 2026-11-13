//go:build live

package core

import (
	"bufio"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

// 隔离实验：exe 日志里目录类请求是 mode=minimal（只 Gorgon），播放请求是 mode=full。
// 用我们的签名器按 minimal 重放一条真实目录请求：
//   - 有数据 → Gorgon / UA / query 构造链路正常，问题被隔离到 full 模式（Helios/Medusa）或 body
//   - 空      → 连 minimal 都对不上，基础链路就有问题
//
//	go test -tags live ./core/ -run TestLiveMinimalReplay -v -timeout 120s
func TestLiveMinimalReplay(t *testing.T) {
	const dumpPath = `F:\hongguodesk\hgdump.log`
	file, err := os.Open(dumpPath)
	if err != nil {
		t.Skipf("没有 dump 文件: %v", err)
	}
	defer file.Close()

	var target string
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 1<<20), 1<<20)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.Contains(line, "mode=minimal") {
			continue
		}
		index := strings.Index(line, "url=")
		if index < 0 {
			continue
		}
		candidate := strings.TrimSpace(line[index+4:])
		if strings.Contains(candidate, "bookmall/tab") {
			target = candidate
			break
		}
	}
	if target == "" {
		t.Skip("dump 里没有找到目录请求")
	}
	t.Logf("重放: %.160s", target)

	// dump 里的时间戳是旧的，服务端会判过期，必须换成当前时间再签名
	khronos := uint32(time.Now().Unix())
	ticket := uint64(time.Now().UnixMilli())
	parsed, err := url.Parse(target)
	if err != nil {
		t.Fatalf("URL 解析失败: %v", err)
	}
	values := parsed.Query()
	values.Set("_rticket", fmt.Sprintf("%d", ticket))
	values.Set("ts", fmt.Sprintf("%d", khronos))
	parsed.RawQuery = values.Encode()
	target = parsed.String()
	query := parsed.RawQuery
	device := hongguoDevicePool()[0]

	request, err := http.NewRequest(http.MethodGet, target, nil)
	if err != nil {
		t.Fatalf("构造失败: %v", err)
	}
	request.Header.Set("User-Agent", device.UserAgent)
	request.Header.Set("Accept", hongguoAcceptHeader)
	request.Header.Set("X-Khronos", fmt.Sprintf("%d", khronos))
	request.Header.Set("X-SS-Req-Ticket", fmt.Sprintf("%d", ticket))
	request.Header.Set("X-Gorgon", hongguoXGorgon(query, nil, khronos, hongguoRandom32()%65536))

	_ = query

	client := &http.Client{Timeout: 15 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		t.Fatalf("请求失败: %v", err)
	}
	content, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
	response.Body.Close()
	head := string(content)
	if len(head) > 200 {
		head = head[:200]
	}
	t.Logf("精简头 HTTP=%d len=%d  %s", response.StatusCode, len(content), head)

	// 再用工程完整头套件发一次
	full := hongguoSignSuite(device, target, nil, khronos, ticket)
	request2, _ := http.NewRequest(http.MethodGet, target, nil)
	for name, value := range full {
		request2.Header.Set(name, value)
	}
	response2, err := client.Do(request2)
	if err != nil {
		t.Fatalf("第二次请求失败: %v", err)
	}
	content2, _ := io.ReadAll(io.LimitReader(response2.Body, 4096))
	response2.Body.Close()
	head2 := string(content2)
	if len(head2) > 200 {
		head2 = head2[:200]
	}
	t.Logf("完整套件 HTTP=%d len=%d  %s", response2.StatusCode, len(content2), head2)
}
