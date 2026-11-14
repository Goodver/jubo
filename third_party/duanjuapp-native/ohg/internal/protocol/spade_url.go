package protocol

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
)

// ErrSpadeURL 表示媒体 URL 的密文无法解开。
var ErrSpadeURL = errors.New("spade media URL cannot be decrypted")

// spadeURLConstants 是媒体 URL 派生使用的 64 字节常量段。
// 与 spade_a 解包（internal/drm）无关，只用于 key_seed 这条 URL 加密链路。
var spadeURLConstants = func() []byte {
	const hexConstants = "4dd4c2e6b83162090e52b3c7a6733ba4" +
		"1cb2462b829ab58a196b39db57177524" +
		"f49baf7f08e8d68d26a72e37c1a95a2f" +
		"1f05a51892aef2949732b62a38aadd58"
	b, err := hex.DecodeString(hexConstants)
	if err != nil {
		panic("protocol: spade URL constants are not valid hex")
	}
	return b
}()

// DecryptSpadeURL 解开以 key_seed 加密的媒体 URL。
//
// 播放模型带 key_seed 时，video_list 里的 main_url / backup_url 是密文：
// 前 4 字节为 a8 ?? 01 00 的信封头，其后是 16 字节整块的 AES-128-CBC 密文。
// 密钥与 IV 由 seed 的 SHA-512 再拼常量段做一次 SHA-512 派生。
//
// seedBase64 是模型里 key_seed 字段的原值（base64），不是解码后的字节。
// 模型不带 key_seed 时不要调用本函数，URL 本来就是明文。
func DecryptSpadeURL(value, seedBase64 string) (string, error) {
	seed, err := decodeBase64Loose(seedBase64)
	if err != nil {
		return "", fmt.Errorf("%w: seed is not base64: %v", ErrSpadeURL, err)
	}
	if len(seed) == 0 {
		return "", fmt.Errorf("%w: seed is empty", ErrSpadeURL)
	}
	return decryptSpadeURL(value, seed)
}

// decryptSpadeURL 是 DecryptSpadeURL 的实际实现，接受已解码的 seed，
// 方便测试直接构造黄金向量。
func decryptSpadeURL(value string, seed []byte) (string, error) {
	raw, err := decodeBase64Loose(value)
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrSpadeURL, err)
	}
	if len(raw) < 5 {
		return "", fmt.Errorf("%w: ciphertext is too short", ErrSpadeURL)
	}
	if raw[0] != 0xa8 || raw[2] != 0x01 || raw[3] != 0x00 {
		return "", fmt.Errorf("%w: unexpected envelope header", ErrSpadeURL)
	}
	cipherLength := (len(raw) - 4) / aes.BlockSize * aes.BlockSize
	if cipherLength == 0 {
		return "", fmt.Errorf("%w: no complete cipher block", ErrSpadeURL)
	}

	h1 := sha512.Sum512(seed)
	h := sha512.New()
	h.Write(h1[:])
	h.Write(spadeURLConstants)
	sum := h.Sum(nil)

	block, err := aes.NewCipher(sum[:16])
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrSpadeURL, err)
	}
	plain := make([]byte, cipherLength)
	cipher.NewCBCDecrypter(block, sum[16:32]).CryptBlocks(plain, raw[4:4+cipherLength])

	// 服务端用 PKCS#7 补块，但末尾也可能带零填充；两者都容忍。
	if n := len(plain); n > 0 {
		if pad := int(plain[n-1]); pad >= 1 && pad <= aes.BlockSize && pad <= n {
			plain = plain[:n-pad]
		}
	}
	plain = bytes.TrimRight(plain, "\x00")
	return string(plain), nil
}

// decodeBase64Loose 按标准 base64 优先解码，兼容缺 padding 与 URL-safe 变体。
// 服务端下发的 base64 不一定带填充，这里不做严格校验。
func decodeBase64Loose(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, errors.New("empty base64 input")
	}
	for _, enc := range []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	} {
		if b, err := enc.DecodeString(s); err == nil {
			return b, nil
		}
	}
	return nil, errors.New("invalid base64 input")
}
