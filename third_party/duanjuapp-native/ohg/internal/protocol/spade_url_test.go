package protocol

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha512"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
)

// sealSpadeURLForTest 用与解密相反的路径构造密文，验证派生链自洽。
func sealSpadeURLForTest(t *testing.T, plain string, seed []byte) string {
	t.Helper()
	body := []byte(plain)
	pad := aes.BlockSize - len(body)%aes.BlockSize
	body = append(body, bytes.Repeat([]byte{byte(pad)}, pad)...)

	h1 := sha512.Sum512(seed)
	h := sha512.New()
	h.Write(h1[:])
	h.Write(spadeURLConstants)
	sum := h.Sum(nil)

	block, err := aes.NewCipher(sum[:16])
	if err != nil {
		t.Fatalf("aes: %v", err)
	}
	out := make([]byte, len(body))
	cipher.NewCBCEncrypter(block, sum[16:32]).CryptBlocks(out, body)

	envelope := append([]byte{0xa8, 0x37, 0x01, 0x00}, out...)
	return base64.StdEncoding.EncodeToString(envelope)
}

func TestDecryptSpadeURLRoundTrip(t *testing.T) {
	seed := []byte("0123456789abcdef")
	want := "https://qznovelvod.com/video/abc.mp4?x-expires=1790000000&x-signature=deadbeef"
	sealed := sealSpadeURLForTest(t, want, seed)

	got, err := decryptSpadeURL(sealed, seed)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestDecryptSpadeURLFromBase64Seed(t *testing.T) {
	seed := []byte{0x11, 0x22, 0x33, 0x44, 0x55}
	want := "https://douyinvod.com/x.mp4"
	sealed := sealSpadeURLForTest(t, want, seed)

	got, err := DecryptSpadeURL(sealed, base64.StdEncoding.EncodeToString(seed))
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestDecryptSpadeURLRejectsBadEnvelope(t *testing.T) {
	seed := []byte("seed")
	sealed := sealSpadeURLForTest(t, "https://a.b/c.mp4", seed)
	raw, err := base64.StdEncoding.DecodeString(sealed)
	if err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	raw[0] = 0xa9 // 只改信封首字节

	if _, err := decryptSpadeURL(base64.StdEncoding.EncodeToString(raw), seed); !errors.Is(err, ErrSpadeURL) {
		t.Fatalf("expected ErrSpadeURL, got %v", err)
	}
}

func TestDecryptSpadeURLRejectsShortCiphertext(t *testing.T) {
	seed := []byte("seed")
	short := base64.StdEncoding.EncodeToString([]byte{0xa8, 0x01, 0x01, 0x00, 0x01})

	if _, err := decryptSpadeURL(short, seed); !errors.Is(err, ErrSpadeURL) {
		t.Fatalf("expected ErrSpadeURL, got %v", err)
	}
}

func TestDecryptSpadeURLAcceptsUnpaddedBase64(t *testing.T) {
	seed := []byte("seed")
	want := "https://fqnovelvod.com/a.mp4"
	sealed := strings.TrimRight(sealSpadeURLForTest(t, want, seed), "=")

	got, err := decryptSpadeURL(sealed, seed)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}
