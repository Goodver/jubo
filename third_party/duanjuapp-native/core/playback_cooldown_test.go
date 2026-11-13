package core

import (
	"strings"
	"testing"
	"time"
)

// 2026-11-07 实机回归：主接口整体静默限流时不能继续狂发请求，
// 也不能再提示用户去填 did（实测换真 did 一样是空包）。
func TestSilentLimitCooldown(t *testing.T) {
	hongguoSilentLimit.Lock()
	savedStreak, savedUntil := hongguoSilentLimit.streak, hongguoSilentLimit.until
	hongguoSilentLimit.streak, hongguoSilentLimit.until = 0, time.Time{}
	hongguoSilentLimit.Unlock()
	defer func() {
		hongguoSilentLimit.Lock()
		hongguoSilentLimit.streak, hongguoSilentLimit.until = savedStreak, savedUntil
		hongguoSilentLimit.Unlock()
	}()

	if hongguoSilentCooldown() {
		t.Fatal("初始状态不该处于冷却")
	}
	hongguoNoteSilentEmpty("红果取流接口返回空内容（平台限流）")
	if hongguoSilentCooldown() {
		t.Fatal("单次空包不该立刻进入冷却")
	}
	hongguoNoteSilentEmpty("红果取流接口返回空内容（平台限流）")
	if !hongguoSilentCooldown() {
		t.Fatal("连续两轮空包应进入冷却")
	}
	hongguoNotePlaybackSuccess()
	if hongguoSilentCooldown() {
		t.Fatal("取流成功后应清除冷却")
	}
	hongguoNoteSilentEmpty("取流接口 HTTP 503")
	if hongguoSilentCooldown() {
		t.Fatal("非静默空包错误不该触发冷却")
	}
}

func TestSilentEmptyMessageDoesNotBlameCustomDevice(t *testing.T) {
	_, err := decodeHongguoMediaModel(nil)
	if err == nil {
		t.Fatal("空 body 必须报错")
	}
	message := err.Error()
	if strings.Contains(message, "自定义设备") || strings.Contains(message, "did/uid") {
		t.Fatalf("空包提示仍在误导用户去填 did: %s", message)
	}
	if !strings.Contains(message, "限流") {
		t.Fatalf("空包提示应说明是限流/身份未被认可: %s", message)
	}
}
