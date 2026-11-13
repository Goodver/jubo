package core

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// 红果 App 设备身份池与自定义设备号。
//
// 1.2.20 的桌面客户端在取播放地址时不再只用一套设备身份：它把「多套设备身份 ×
// 多条接口线路」并发发出去，谁先拿到可用的 video_list 就用谁。官方更新日志写的是
// 「各设备/线路同时取播放地址，谁先成功用谁」，并把「填自己手机红果 App 的
// 设备号（did/uid）」作为兜底。
//
// 这里的字段名与 hongguoDeviceQuery 严格对齐，只换值不换字段名：1.2.17 的经验是
// 增删 query 字段会直接触发风控空响应，换值不会。

type hongguoDeviceProfile struct {
	Name        string
	Brand       string // device_brand
	Model       string // device_type
	OSVersion   string // os_version
	OSAPI       string // os_api
	Resolution  string
	DPI         string
	Channel     string
	UserAgent   string
	HostABI     string
	DeviceID    string
	InstallID   string
	IID         string
	CDID        string
	OpenUDID    string
	DeviceToken string
	TtReq       string
	StoreRegion string
	// 只有拿得到 device_token/ttreq 的身份才能走完整套件；没有 token 的身份
	// 只发身份字段（对应桌面端 minimal 套件），用来撞不同设备身份的风控容差。
	TokenBound bool
	Custom     bool
	UID        string
}

func hongguoRandomHex(length int) string {
	if length < 2 {
		length = 2
	}
	buffer := make([]byte, length/2)
	if _, err := rand.Read(buffer); err != nil {
		return strings.Repeat("0", length)
	}
	return hex.EncodeToString(buffer)
}

func hongguoRandomUUID() string {
	text := hongguoRandomHex(32)
	return text[0:8] + "-" + text[8:12] + "-" + text[12:16] + "-" + text[16:20] + "-" + text[20:32]
}

func hongguoDeviceAgent(display, android string) string {
	return "com.phoenix.read/73932 (Linux; U; Android " + android + "; zh_CN; " + display +
		"; Build/UKQ1.230804.001; Cronet/TTNetVersion:8d40f833 QuicVersion:462f352c 2026-08-31)"
}

// hongguoDevicePool 返回按优先级排好的设备身份。第 0 个是带 device_token/ttreq 的
// 已注册设备（1.2.17 起实测可用），其余是不带 token 的身份变体，只在第一轮全部
// 失败时才参与竞速。
func hongguoDevicePool() []hongguoDeviceProfile {
	primary := hongguoDeviceProfile{
		Name: "xiaomi_14", Brand: "xiaomi", Model: "23127PN0CC",
		OSVersion: "14", OSAPI: "34", Resolution: "1200*2670", DPI: "460",
		Channel: "xiaomi_8662_64", UserAgent: hongguoMediaUserAgent, HostABI: "arm64-v8a",
		DeviceID: hongguoMediaDeviceID, InstallID: hongguoMediaInstallID, IID: hongguoMediaIID,
		CDID: hongguoMediaCDID, OpenUDID: hongguoMediaOpenUDID,
		DeviceToken: hongguoMediaDeviceToken, TtReq: hongguoMediaTtReq,
		StoreRegion: hongguoMediaStoreRegion, TokenBound: true,
	}
	variants := []hongguoDeviceProfile{
		{Name: "xiaomi_13", Brand: "xiaomi", Model: "2211133C", OSVersion: "14", OSAPI: "34",
			Resolution: "1080*2400", DPI: "440", Channel: "xiaomi_8662_64"},
		{Name: "vivo_x100", Brand: "vivo", Model: "V2309A", OSVersion: "14", OSAPI: "34",
			Resolution: "1260*2800", DPI: "453", Channel: "vivo_8662_64"},
		{Name: "huawei_mate60", Brand: "harmonyos", Model: "ALN-AL00", OSVersion: "12", OSAPI: "31",
			Resolution: "1220*2700", DPI: "480", Channel: "huawei_8662_64"},
		{Name: "honor_magic6", Brand: "magicos", Model: "BVL-AN16", OSVersion: "14", OSAPI: "34",
			Resolution: "1264*2780", DPI: "460", Channel: "honor_8662_64"},
		{Name: "oppo_findx7", Brand: "coloros", Model: "PHZ110", OSVersion: "14", OSAPI: "34",
			Resolution: "1264*2780", DPI: "510", Channel: "oppo_8662_64"},
		{Name: "oneplus_12", Brand: "OnePlus", Model: "PJD110", OSVersion: "14", OSAPI: "34",
			Resolution: "1440*3168", DPI: "510", Channel: "oneplus_8662_64"},
		{Name: "samsung_s24u", Brand: "samsung", Model: "SM-S9280", OSVersion: "14", OSAPI: "34",
			Resolution: "1440*3120", DPI: "505", Channel: "samsung_8662_64"},
	}
	// 2026-11-07 12:20：注册设备 did 4016988545905888 在密集调用后已被风控
	// （HTTP 200 + 空 body），同一时刻旧版注册身份 1905922028880368 仍能
	// 返回完整 video_model（code:0）。把它排到池首，默认取流优先撞这个
	// 还能用的身份；原主身份保留在第二位，其余池内身份继续作为后续轮次。
	legacy := primary
	legacy.Name = "legacy_registered"
	legacy.DeviceID = "1905922028880368"
	legacy.InstallID = "1905922028884464"
	legacy.IID = "1905922028884464"
	pool := make([]hongguoDeviceProfile, 0, len(variants)+2)
	pool = append(pool, legacy, primary)
	for _, device := range variants {
		device.UserAgent = hongguoDeviceAgent(hongguoDisplayModel(device.Name), device.OSVersion)
		device.HostABI = "arm64-v8a"
		device.StoreRegion = hongguoMediaStoreRegion
		device.DeviceID = hongguoStableDeviceID(device.Name, 1)
		device.InstallID = hongguoStableDeviceID(device.Name, 2)
		device.IID = device.InstallID
		device.CDID = hongguoStableUUID(device.Name)
		device.OpenUDID = hongguoStableHex("hg-openudid:"+device.Name, 16)
		pool = append(pool, device)
	}
	return pool
}

func hongguoDisplayModel(name string) string {
	switch name {
	case "xiaomi_14":
		return "Xiaomi 14"
	case "xiaomi_13":
		return "Xiaomi 13"
	case "vivo_x100":
		return "vivo X100"
	case "huawei_mate60":
		return "ALN-AL00"
	case "honor_magic6":
		return "BVL-AN16"
	case "oppo_findx7":
		return "PHZ110"
	case "oneplus_12":
		return "PJD110"
	case "samsung_s24u":
		return "SM-S9280"
	}
	return name
}

// hongguoStableDeviceID 为身份变体生成稳定的 19 位设备号：同一身份每次运行都是
// 同一个号，避免服务端看到「设备号每次都变」而直接判为异常。
func hongguoStableDeviceID(name string, role int) string {
	sum := hongguoSM3([]byte("hg-device:" + name + ":" + strconv.Itoa(role)))
	value := uint64(0)
	for index := 0; index < 8; index++ {
		value = value<<8 | uint64(sum[index])
	}
	text := strconv.FormatUint(value%10_000_000_000_000_000, 10)
	return "19" + strings.Repeat("0", max(0, 17-len(text))) + text
}

func hongguoStableHex(seed string, length int) string {
	sum := hongguoSM3([]byte(seed))
	text := hex.EncodeToString(sum[:])
	if len(text) > length {
		text = text[:length]
	}
	for len(text) < length {
		text += "0"
	}
	return text
}

func hongguoStableUUID(name string) string {
	text := hongguoStableHex("hg-cdid:"+name, 32)
	return text[0:8] + "-" + text[8:12] + "-" + text[12:16] + "-" + text[16:20] + "-" + text[20:32]
}

// hongguoCustomDevice 是用户自己填的红果 App 设备号，作为最后一档兜底。
// 后面的机型字段来自「读取本机 ID」，留空时沿用主设备的机型。
type hongguoCustomDevice struct {
	DID        string `json:"did"`
	UID        string `json:"uid"`
	Brand      string `json:"brand,omitempty"`
	Model      string `json:"model,omitempty"`
	OSVersion  string `json:"osVersion,omitempty"`
	OSAPI      string `json:"osApi,omitempty"`
	Resolution string `json:"resolution,omitempty"`
	DPI        string `json:"dpi,omitempty"`
	ABI        string `json:"abi,omitempty"`
}

func (device hongguoCustomDevice) normalized() hongguoCustomDevice {
	return hongguoCustomDevice{
		DID:        strings.TrimSpace(device.DID),
		UID:        strings.TrimSpace(device.UID),
		Brand:      strings.TrimSpace(device.Brand),
		Model:      strings.TrimSpace(device.Model),
		OSVersion:  strings.TrimSpace(device.OSVersion),
		OSAPI:      strings.TrimSpace(device.OSAPI),
		Resolution: strings.TrimSpace(device.Resolution),
		DPI:        strings.TrimSpace(device.DPI),
		ABI:        strings.TrimSpace(device.ABI),
	}
}

func (device hongguoCustomDevice) configured() bool {
	return device.DID != "" || device.UID != ""
}

func (device hongguoCustomDevice) validate() error {
	if device.DID == "" && device.UID == "" {
		return nil
	}
	if device.DID != "" && (!hongguoNumericID.MatchString(device.DID) || len(device.DID) < 6) {
		return errors.New("设备号（did）应为 6 至 32 位数字")
	}
	if device.UID != "" && (!hongguoNumericID.MatchString(device.UID) || len(device.UID) < 4) {
		return errors.New("用户号（uid）应为 4 至 32 位数字")
	}
	return nil
}

// profile 把自定义设备号映射成一份设备身份：机型字段默认沿用主设备，去掉
// device_token/ttreq（那是别人设备的票据，混用会被判定为票据与设备不匹配），
// uid 走 uid_tt cookie。
//
// 如果用户点过「读取本机 ID」，机型/系统/分辨率/DPI 会换成这台真机的实际值。
// 这一步很关键：只换设备号、机型还留着「Xiaomi 14 + Android 14」的话，
// 服务端拿到的是一条自相矛盾的设备档案，比不填更容易被挑出来。
func (device hongguoCustomDevice) profile() (hongguoDeviceProfile, bool) {
	if !device.configured() {
		return hongguoDeviceProfile{}, false
	}
	profile := hongguoDevicePool()[0]
	profile.Name = "custom_device"
	profile.Custom = true
	profile.TokenBound = false
	profile.DeviceToken = ""
	profile.TtReq = ""
	profile.UID = device.UID
	if device.DID != "" {
		profile.DeviceID = device.DID
		profile.InstallID = device.DID
		profile.IID = device.DID
		profile.CDID = hongguoStableUUID(device.DID)
	}
	if device.Brand != "" {
		profile.Brand = device.Brand
	}
	if device.Model != "" {
		profile.Model = device.Model
	}
	if device.OSVersion != "" {
		profile.OSVersion = device.OSVersion
	}
	if device.OSAPI != "" {
		profile.OSAPI = device.OSAPI
	}
	if device.Resolution != "" {
		profile.Resolution = device.Resolution
	}
	if device.DPI != "" {
		profile.DPI = device.DPI
	}
	if device.ABI != "" {
		profile.HostABI = device.ABI
	}
	// UA 里的机型与系统版本要和上面改过的值一致，否则 UA 会自曝其短。
	if device.Model != "" || device.OSVersion != "" || device.Brand != "" {
		profile.UserAgent = hongguoDeviceAgent(profile.Model, profile.OSVersion)
	}
	return profile, true
}

type hongguoPlaybackDeviceState struct {
	DID        string `json:"did"`
	UID        string `json:"uid"`
	Configured bool   `json:"configured"`
	Brand      string `json:"brand,omitempty"`
	Model      string `json:"model,omitempty"`
	OSVersion  string `json:"osVersion,omitempty"`
	OSAPI      string `json:"osApi,omitempty"`
	Resolution string `json:"resolution,omitempty"`
	DPI        string `json:"dpi,omitempty"`
	ABI        string `json:"abi,omitempty"`
}

func (d *Downloader) attachPlaybackDevice(directory string) {
	d.playbackDeviceMu.Lock()
	d.playbackDevicePath = filepath.Join(directory, "playback-device.json")
	d.playbackDeviceMu.Unlock()
	d.loadPlaybackDevice()
}

func (d *Downloader) loadPlaybackDevice() {
	d.playbackDeviceMu.Lock()
	defer d.playbackDeviceMu.Unlock()
	if d.playbackDevicePath == "" {
		return
	}
	info, err := os.Stat(d.playbackDevicePath)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 4096 {
		return
	}
	data, err := os.ReadFile(d.playbackDevicePath)
	if err != nil || len(data) == 0 {
		return
	}
	var stored hongguoCustomDevice
	if json.Unmarshal(data, &stored) != nil {
		return
	}
	stored = stored.normalized()
	if stored.validate() != nil {
		return
	}
	d.playbackDevice = stored
}

func (d *Downloader) savePlaybackDevice(device hongguoCustomDevice) (hongguoPlaybackDeviceState, error) {
	device = device.normalized()
	if err := device.validate(); err != nil {
		return hongguoPlaybackDeviceState{}, err
	}
	d.playbackDeviceMu.Lock()
	defer d.playbackDeviceMu.Unlock()
	if d.playbackDevicePath == "" {
		return hongguoPlaybackDeviceState{}, errors.New("本地存储尚未就绪")
	}
	data, err := json.Marshal(device)
	if err != nil {
		return hongguoPlaybackDeviceState{}, err
	}
	if err := nativeDownloadWrite(d.playbackDevicePath, data); err != nil {
		return hongguoPlaybackDeviceState{}, errors.New("未能保存播放设备号，原设置保持不变")
	}
	d.playbackDevice = device
	return device.state(), nil
}

func (d *Downloader) currentPlaybackDevice() hongguoCustomDevice {
	d.playbackDeviceMu.Lock()
	defer d.playbackDeviceMu.Unlock()
	return d.playbackDevice
}

func (d *Downloader) playbackDeviceState() hongguoPlaybackDeviceState {
	return d.currentPlaybackDevice().state()
}

func (device hongguoCustomDevice) state() hongguoPlaybackDeviceState {
	return hongguoPlaybackDeviceState{
		DID:        device.DID,
		UID:        device.UID,
		Configured: device.configured(),
		Brand:      device.Brand,
		Model:      device.Model,
		OSVersion:  device.OSVersion,
		OSAPI:      device.OSAPI,
		Resolution: device.Resolution,
		DPI:        device.DPI,
		ABI:        device.ABI,
	}
}
