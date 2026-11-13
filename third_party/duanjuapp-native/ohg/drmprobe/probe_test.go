// Package drmprobe 仅用于现场诊断播放模型的密钥材料格式。
// 它不参与生产构建：以 go test 运行，把真实响应里 spade_a 的每一步解包
// 结果打到日志，用来判断 drm.Derive 在哪一步拒绝了新的服务端材料。
package drmprobe

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"duanjuapp/native/ohg/adapters"
	"duanjuapp/native/ohg/internal/drm"
	"duanjuapp/native/ohg/sdk"
)

// diagnose 是 drm.Derive 的逐行复刻，额外打印每个中间量。
// 返回 nil 表示算法本身接受了这份材料。
func diagnose(spadeA string, log func(string, ...any)) error {
	s := strings.TrimSpace(spadeA)
	log("  spade_a: len=%d head=%q", len(s), head(s, 48))
	raw, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		// 顺带试 URL-safe 与无 padding，判断是不是编码变体。
		if raw2, e2 := base64.RawStdEncoding.DecodeString(s); e2 == nil {
			log("  base64: RawStdEncoding OK (len=%d)", len(raw2))
			raw = raw2
		} else if raw2, e2 := base64.URLEncoding.DecodeString(s); e2 == nil {
			log("  base64: URLEncoding OK (len=%d)", len(raw2))
			raw = raw2
		} else {
			return fmt.Errorf("base64 decode: %w", err)
		}
	} else {
		log("  base64: StdEncoding OK (len=%d)", len(raw))
	}
	if len(raw) < 4 {
		return errors.New("raw too short")
	}
	log("  raw hex[0:24]=%s tail=%s", hex.EncodeToString(raw[:min(24, len(raw))]),
		hex.EncodeToString(raw[max(0, len(raw)-12):]))

	marker := int(raw[0] ^ raw[1] ^ raw[2])
	prefixLen := marker - 0x30
	log("  marker=%d prefixLen=%d", marker, prefixLen)
	if prefixLen < 1 || prefixLen > len(raw) {
		return errors.New("prefixLen out of range")
	}
	outLen := len(raw) - marker + 0x2f
	log("  outLen=%d", outLen)
	if outLen < 2 || 1+outLen > len(raw) {
		return errors.New("outLen out of range")
	}
	tail := len(raw) - prefixLen
	log("  tail=%d", tail)
	if tail-2 < 0 || tail > len(raw) {
		return errors.New("tail out of range")
	}
	b16, b14 := raw[tail-2], raw[tail-1]
	tag := make([]byte, prefixLen)
	for i := range tag {
		if i+tail >= len(raw) {
			return fmt.Errorf("tag[%d] out of range (i+tail=%d len=%d)", i, i+tail, len(raw))
		}
		tag[i] = b14 ^ b16 ^ raw[i+tail]
	}
	log("  b16=%02x b14=%02x tag=%q", b16, b14, string(tag))
	buf := append([]byte(nil), raw[1:1+outLen]...)
	log("  buf(pre-scramble) head=%s", hex.EncodeToString(buf[:min(16, len(buf))]))
	// scramble 与 internal/drm 完全一致，只为拿到最终 buf[0]。
	scramble(buf, strings.HasPrefix(string(tag), "app_v2") || strings.HasPrefix(string(tag), "web_v2"))
	versionLen := hexDigit(buf[0])
	log("  buf(post-scramble) head=%s versionLen=%d", hex.EncodeToString(buf[:min(16, len(buf))]), versionLen)
	if versionLen < 1 || versionLen >= outLen {
		return errors.New("versionLen out of range")
	}
	keyLen := outLen - versionLen
	hexKey := string(buf[1:keyLen])
	log("  keyLen=%d hexKey=%q version=%q", keyLen, head(hexKey, 64), string(buf[keyLen:]))
	if hexKey == "" || len(hexKey)%2 != 0 {
		return errors.New("hexKey empty or odd length")
	}
	for i := 0; i < len(hexKey); i++ {
		if hexDigit(hexKey[i]) < 0 {
			return fmt.Errorf("non-hex byte at %d (%q)", i, hexKey[i])
		}
	}
	return nil
}

func head(s string, n int) string {
	if len(s) > n {
		return s[:n] + "..."
	}
	return s
}

func hexDigit(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}

func scramble(buf []byte, v2 bool) {
	if v2 {
		last := len(buf) - 1
		for i := 0; i+1 < len(buf); i += 2 {
			buf[i], buf[i+1] = buf[i+1], buf[i]
			if i == last-2 {
				break
			}
		}
	}
	var prev, cur byte = 0x55, 0xfa
	for i := range buf {
		b := buf[i]
		term := -byte(0x15 + popcount(uint32(i)))
		if i%2 == 0 {
			if v2 {
				buf[i] = (cur ^ b) - prev + term
			} else {
				buf[i] = term + (cur ^ b)
			}
			cur = b
		} else {
			if v2 {
				buf[i] = (prev ^ b) - prev + term
			} else {
				buf[i] = term + (prev ^ b)
			}
			prev = b
		}
	}
}

func popcount(v uint32) int {
	return int(bits8(byte(v)) + bits8(byte(v>>8)) + bits8(byte(v>>16)) + bits8(byte(v>>24)))
}

func bits8(v byte) byte {
	var n byte
	for v != 0 {
		v &= v - 1
		n++
	}
	return n
}

func inspect(t *testing.T, client *sdk.Client, ctx context.Context, label, episodeID string) {
	t.Helper()
	t.Logf("=== %s episodeID=%s ===", label, episodeID)
	pb, err := client.ResolvePlayback(ctx, episodeID, sdk.PlaybackOptions{})
	if err != nil && !errors.Is(err, sdk.ErrDRMProtected) {
		t.Logf("  ResolvePlayback FAILED: %v", err)
		return
	}
	if pb == nil {
		t.Logf("  ResolvePlayback returned nil model (err=%v)", err)
		return
	}
	t.Logf("  protected=%v streams=%d videoID=%s keyMaterial.len=%d",
		pb.Protected, len(pb.Streams), pb.VideoID, len(pb.KeyMaterial))
	for i, s := range pb.Streams {
		if i >= 3 {
			break
		}
		t.Logf("  stream[%d] %dx%d codec=%s encrypted=%v method=%q hls=%v dash=%v",
			i, s.Width, s.Height, s.Codec, s.Protected, s.Encryption, s.HLS, s.Dash)
	}
	key, keyErr := sdk.ContentKey(pb)
	t.Logf("  ContentKey: err=%v key.hex.len=%d version=%q", keyErr, len(key.Hex), key.Version)
	_, deriveErr := drm.Derive(pb.KeyMaterial)
	t.Logf("  drm.Derive: err=%v", deriveErr)
	if diagErr := diagnose(pb.KeyMaterial, t.Logf); diagErr != nil {
		t.Logf("  DIAG REJECT: %v", diagErr)
	} else {
		t.Logf("  DIAG ACCEPT")
	}
}

func TestDRMDiag(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	profile := t.TempDir() + "/profile.json"
	client, err := adapters.NewClient(profile, sdk.Options{
		RetryAttempts: 2,
		DeviceResets:  sdk.Int(2),
	})
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}

	// 允许用环境变量直接指定分集 ID，跳过搜索以节省设备额度。
	if ids := os.Getenv("OHG_PROBE_EPISODES"); ids != "" {
		for _, id := range strings.Split(ids, ",") {
			inspect(t, client, ctx, "env:"+strings.TrimSpace(id), strings.TrimSpace(id))
		}
		return
	}

	queries := []string{
		"下山送信竟成了国公府赘婿",
		"一九八零，福妻种菇养全家",
	}
	for _, q := range queries {
		res, searchErr := client.Search(ctx, q, sdk.SearchOptions{})
		if searchErr != nil {
			t.Logf("search %q FAILED: %v", q, searchErr)
			continue
		}
		t.Logf("search %q -> %d hits", q, len(res.Items))
		for i, s := range res.Items {
			if i >= 2 {
				break
			}
			t.Logf("  hit[%d] id=%s title=%q eps=%d", i, s.ID, s.Title, s.EpisodeCount)
			eps, epErr := client.ListEpisodes(ctx, s.ID, sdk.EpisodeOptions{})
			if epErr != nil {
				t.Logf("  ListEpisodes FAILED: %v", epErr)
				continue
			}
			if len(eps.Items) == 0 {
				t.Logf("  ListEpisodes empty")
				continue
			}
			inspect(t, client, ctx, q+" 第1集", eps.Items[0].ID)
		}
	}
}
