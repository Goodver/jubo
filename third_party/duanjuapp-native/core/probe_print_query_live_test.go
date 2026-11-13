//go:build live

package core

import (
	"fmt"
	"testing"
	"time"
)

// 打印工程构造的播放 query，用于和 exe 的真实 query 逐字节对比。
//
//	go test -tags live ./core/ -run TestLivePrintQuery -v -timeout 60s
func TestLivePrintQuery(t *testing.T) {
	khronos := uint32(1793771653)
	ticket := uint64(1793771653595)
	query := hongguoPlaybackQuery("621699152495976", "428185093167591", khronos, ticket)
	fmt.Printf("QUERY_BEGIN%sQUERY_END\n", query)

	// 同时打印 Gorgon / Helios / Medusa，方便人工核对长度与形态
	body := hongguoMediaPayload("7691759547454606361")
	rawURL := "https://api5-normal-lq.fqnovel.com" + hongguoMultiVideoPath + "?" + query
	fmt.Printf("GORGON=%s\n", hongguoXGorgon(query, body, khronos, 0x1234))
	fmt.Printf("HELIOS=%s\n", hongguoHelios(khronos))
	fmt.Printf("MEDUSA=%s\n", hongguoBuildMedusa(rawURL, body, khronos, "621699152495976", "7.1.3.32"))
	fmt.Printf("BODY=%s\n", string(body))
	_ = time.Now
}
