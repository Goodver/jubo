package sdk

import (
	"errors"
	"strings"
	"testing"

	"duanjuapp/native/ohg/sdk/model"
)

// 2026-11-08：把「模型根本没有密钥材料」与「材料格式无法识别」区分开，
// 前者通常是明文流被误标，排障时不必再去怀疑 drm.Derive 的算法。
func TestContentKeyMissingMaterial(t *testing.T) {
	pb := &model.Playback{
		Protected: true,
		Streams:   []model.Stream{{URL: "https://cdn.example.com/clear.mp4"}},
	}
	_, err := ContentKey(pb)
	if err == nil {
		t.Fatal("缺少密钥材料的受保护模型没有报错")
	}
	if !errors.Is(err, ErrDRMProtected) {
		t.Fatalf("错误应能匹配 ErrDRMProtected: %v", err)
	}
	if !strings.Contains(err.Error(), "no key material") {
		t.Fatalf("错误信息没有指出缺少密钥材料: %v", err)
	}
	if strings.Contains(err.Error(), "unrecognized key material") {
		t.Fatalf("不应再误报成解包算法失败: %v", err)
	}
}

func TestContentKeyClearModel(t *testing.T) {
	pb := &model.Playback{
		Protected: false,
		Streams:   []model.Stream{{URL: "https://cdn.example.com/clear.mp4"}},
	}
	_, err := ContentKey(pb)
	if !errors.Is(err, ErrNotProtected) {
		t.Fatalf("明文模型应返回 ErrNotProtected, got %v", err)
	}
}
