package core

import (
	"crypto/md5"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// 红果请求的完整签名套件。
//
// 这一套是逐项对着 exe 真实发出的请求头定的（GODEBUG=http2debug=2 把每个
// header 字段都打了出来），并用「缺项 → 空响应」做了正交验证：
//
//	必需：X-Khronos / X-Gorgon / X-Helios / X-Medusa / X-SS-Stub /
//	      X-SS-Req-Ticket / X-TT-DT / X-TT-Trace-Id，以及
//	      lc / x-ss-dp / passport-sdk-version / x-vc-bdturing-sdk-version /
//	      x-tt-store-region / x-tt-store-region-src / x-xs-from-web / accept
//	可选：X-Argus / X-Ladon（客户端只在 Turing SDK 产出真值时才发；发伪造值有害无益）
//
// 早先版本发了 X-TT-Request-Tag / Sdk-Version / X-TT-DT（空值）等客户端根本没有的头，
// 却漏了 X-TT-DT 真值、X-TT-Trace-Id、x-ss-dp 等，结果固定 200 空包。

const (
	hongguoSdkVersion       = "2"
	hongguoPassportSdkVer   = "5051452"
	hongguoBdturingVersion  = "4.0.3.cn"
	hongguoMediaContentType = "application/json; charset=utf-8"
	hongguoAcceptHeader     = "application/json; charset=utf-8,application/x-protobuf"

	// hongguoTtRequestTag 仅保留给历史探针用例编译使用。
	// 真实客户端并不发 X-TT-Request-Tag，生产代码已不再引用。
	hongguoTtRequestTag = "0000000000000000000000000000000000000000"
)

func hongguoRawQuery(rawURL string) string {
	if index := strings.IndexByte(rawURL, '?'); index >= 0 {
		return rawURL[index+1:]
	}
	return ""
}

// hongguoSignSuite 返回一次请求需要的全部签名头与 Cookie。
// body 传 nil 表示无请求体（GET），此时不发 X-SS-Stub。
func hongguoSignSuite(device hongguoDeviceProfile, rawURL string, body []byte, khronos uint32, ticket uint64) map[string]string {
	query := hongguoRawQuery(rawURL)
	// 随机数必须压到 16 位：X-Gorgon 的头部只回写两个字节，用满 32 位会让
	// 服务端无法从头部还原随机数，签名一致性检查直接判失败。
	random := hongguoRandom32() % 65536
	agent := device.UserAgent
	if agent == "" {
		agent = hongguoMediaUserAgent
	}
	headers := map[string]string{
		"User-Agent":                agent,
		"Accept":                    hongguoAcceptHeader,
		"Content-Type":              hongguoMediaContentType,
		"Lc":                        "101",
		"Sdk-Version":               hongguoSdkVersion,
		"Passport-Sdk-Version":      hongguoPassportSdkVer,
		"X-VC-BDTuring-SDK-Version": hongguoBdturingVersion,
		"X-SS-DP":                   "8662",
		"X-Xs-From-Web":             "0",
		"X-Tt-Store-Region":         "cn",
		"X-Tt-Store-Region-Src":     "uid",
		"X-Tt-Dt":                   device.DeviceToken,
		"X-TT-Trace-Id":             hongguoNewTraceID(),
		"X-Khronos":                 strconv.FormatUint(uint64(khronos), 10),
		"X-SS-Req-Ticket":           strconv.FormatUint(ticket, 10),
		"X-Gorgon":                  hongguoXGorgon(query, body, khronos, random),
		"X-Helios":                  hongguoHelios(khronos),
		"X-Medusa":                  hongguoBuildMedusa(rawURL, body, khronos, hongguoPlaybackDeviceID, hongguoMediaVersion),
	}
	if body != nil {
		sum := md5.Sum(body)
		headers["X-SS-Stub"] = strings.ToUpper(hex.EncodeToString(sum[:]))
	}
	if device.DeviceToken == "" {
		delete(headers, "X-Tt-Dt")
	}
	if cookie := hongguoSignCookie(device, ticket); cookie != "" {
		headers["Cookie"] = cookie
	}
	return headers
}

// hongguoNewTraceID 生成 00-<8hex><18hex>-<16hex>-01 形式的 Trace-Id。
func hongguoNewTraceID() string {
	high := fmt.Sprintf("%08x", uint32(time.Now().UnixNano())&0xffffffff)
	mid := hongguoRandomHex(9)
	low := high[:8] + hongguoRandomHex(4)
	return "00-" + high + mid + "-" + low + "-01"
}

// hongguoSignCookie 拼签名相关的 Cookie：客户端发的是 install_id=<iid>。
func hongguoSignCookie(device hongguoDeviceProfile, ticket uint64) string {
	iid := device.IID
	if iid == "" {
		iid = hongguoMediaIID
	}
	return "install_id=" + iid
}

// 以下两个小工具仅为历史探针保留：X-Argus / X-Ladon 的真实值来自 Turing SDK，
// 客户端只在拿到真值时才发；此处用 khronos 拼出来的只是旧探针的占位值，
// 生产路径（hongguoSignSuite）不会发送这两个头。
func hongguoBigEndian32(value uint32) []byte {
	buffer := make([]byte, 4)
	binary.BigEndian.PutUint32(buffer, value)
	return buffer
}

func hongguoLittleEndian32(value uint32) []byte {
	buffer := make([]byte, 4)
	binary.LittleEndian.PutUint32(buffer, value)
	return buffer
}
