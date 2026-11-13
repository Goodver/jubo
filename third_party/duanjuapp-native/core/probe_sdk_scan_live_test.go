//go:build live

package core

import (
	"bytes"
	"crypto/md5"
	"encoding/binary"
	"encoding/hex"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

// 定向扫描 X-Gorgon 的 sdk 版本常量（按 7.1.3.32 的各种编码方式）。
//
//	go test -tags live ./core/ -run TestLiveSdkScan -v -timeout 240s
func TestLiveSdkScan(t *testing.T) {
	videoID := "7693569481984969752"
	host := "https://api5-normal-lq.fqnovel.com"
	path := "/novel/player/multi_video_model/v1/"

	device := hongguoDevicePool()[0]
	device.DeviceID = "3260526922310188"
	device.Brand = "Redmi"
	device.Model = "25053RT47C"
	device.OSVersion = "16"
	device.OSAPI = "36"
	device.Resolution = "1280*2772"
	device.DPI = "520"
	device.Channel = "update_64"

	buildQuery := func() string {
		khronos := time.Now().Unix()
		rticket := time.Now().UnixMilli()
		pairs := [][2]string{
			{"ac", "wifi"}, {"aid", "8662"}, {"app_name", "novelread"},
			{"channel", "update_64"}, {"device_brand", "Redmi"},
			{"device_id", "3260526922310188"}, {"device_platform", "android"},
			{"device_type", "25053RT47C"}, {"dpi", "520"}, {"iid", ""},
			{"language", "zh"}, {"manifest_version_code", "71332"},
			{"os", "android"}, {"os_api", "36"}, {"os_version", "16"},
			{"resolution", "1280*2772"}, {"ssmix", "a"},
			{"update_version_code", "71332"}, {"version_code", "71332"},
			{"version_name", "7.1.3.32"},
		}
		var b strings.Builder
		b.WriteString("_rticket=" + strconv.FormatInt(rticket, 10))
		for _, kv := range pairs {
			b.WriteString("&" + kv[0] + "=" + hongguoQueryEscape(kv[1]))
		}
		b.WriteString("&ts=" + strconv.FormatInt(khronos, 10))
		return b.String()
	}

	gorgonLE := func(query string, body []byte, timestamp, random uint32, sdk uint32) string {
		input := make([]byte, 0, 20)
		qh := md5.Sum([]byte(query))
		input = append(input, qh[:4]...)
		bh := md5.Sum(body)
		input = append(input, bh[:4]...)
		input = append(input, make([]byte, 4)...)
		sdkBuf := make([]byte, 4)
		binary.LittleEndian.PutUint32(sdkBuf, sdk)
		input = append(input, sdkBuf...)
		stamp := make([]byte, 4)
		binary.BigEndian.PutUint32(stamp, timestamp)
		input = append(input, stamp...)
		key := []byte{0x4a, 0x40, 0x16, byte(random >> 8 & 255), 0x47, 0x6c, 0x01, byte(random & 255)}
		out := hongguoRC4Gorgon(input, key)
		for i := 0; i < len(out); i++ {
			value := out[i]>>4 | out[i]<<4
			next := out[0]
			if i+1 < len(out) {
				next = out[i+1]
			}
			out[i] = ^(hongguoReverseBits((next^value)&255) ^ 20)
		}
		prefix := []byte{0x84, 0x04, byte(random & 255), byte(random >> 8 & 255), 0x40, 0x01}
		return hex.EncodeToString(append(prefix, out...))
	}

	// 7.1.3.32 的各种版本编码
	sdks := []struct {
		name string
		val  uint32
	}{
		{"0x07010300", 0x07010300},
		{"0x07010320", 0x07010320},
		{"0x07010332", 0x07010332},
		{"0x00010703", 0x00010703},
		{"0x07030100", 0x07030100},
		{"0x01070300", 0x01070300},
		{"0x04060100(基准)", 0x04060100},
		{"0x07010302", 0x07010302},
		{"0x00071332", 0x00071332},
		{"0x07130300", 0x07130300},
	}

	for _, s := range sdks {
		body := hongguoMediaPayload(videoID)
		khronos := uint32(time.Now().Unix())
		rticket := time.Now().UnixMilli()
		random := hongguoRandom32() % 65536
		query := buildQuery()
		rawURL := host + path + "?" + query

		req, _ := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(body))
		req.Header.Set("User-Agent", device.UserAgent)
		req.Header.Set("Accept", hongguoAcceptHeader)
		req.Header.Set("Content-Type", hongguoMediaContentType)
		req.Header.Set("X-Khronos", strconv.FormatUint(uint64(khronos), 10))
		req.Header.Set("X-Gorgon", gorgonLE(query, body, khronos, random, s.val))
		req.Header.Set("X-SS-Req-Ticket", strconv.FormatInt(rticket, 10))
		sum := md5.Sum(body)
		req.Header.Set("X-SS-STUB", strings.ToUpper(hex.EncodeToString(sum[:])))

		client := &http.Client{Timeout: 12 * time.Second}
		resp, err := client.Do(req)
		if err != nil {
			t.Logf("%-18s ERR %v", s.name, err)
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		resp.Body.Close()
		mark := ""
		if len(content) > 0 {
			mark = " <<< 有响应"
		}
		t.Logf("%-18s HTTP=%d len=%d%s", s.name, resp.StatusCode, len(content), mark)
		if len(content) > 0 {
			p := string(content)
			if len(p) > 300 {
				p = p[:300]
			}
			t.Logf("     %s", p)
		}
		time.Sleep(400 * time.Millisecond)
	}
}
