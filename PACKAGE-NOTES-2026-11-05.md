# 打包说明（源码包 · 2026-11-05 修复版）

打包时间：2026-11-06
基线：`hgonly-src-0.6.10-20261104`（资料库「duanjuapp最新1104版」文件夹内，本包不覆盖它）
版本：app 0.6.10+17

先读 `HANDOFF-2026-11-04.md` 了解架构和接口契约，再看本文件。

## 相对 11-04 基线的改动

### 第一轮：静态审计发现的缺陷 + 一个新增 UI bug（11 个源码文件 + 1 个构建配置）

| 文件 | 修复 |
|---|---|
| `app/lib/engine.dart` | resolve 串行队列 `_resolveTail` + `stillValid`，作废票不再"撞号重试"反杀当前请求 |
| `app/lib/feed_page.dart` | 新增 `_revealUi()` 修「播 4 秒控制层隐藏后上滑换剧信息不回来」；补 `resumed` 分支；`_booting` 防重入 + 重试重置索引/dispose 旧 PageController；`_videoReady` 提前 + 倍速/补 seek 拆出单独 catch |
| `app/lib/models.dart` | `as Map` 强转改 `is Map` 过滤 |
| `native/main.go` | `HgFree` 用 `sync.Map` 做所有权校验 |
| `core/app_stream.go` | 流代理 `Timeout: 0` → 5 分钟 |
| `core/network_limiter.go` | 限流额度归还加 `sync.Once` + `context.AfterFunc` 兜底 |
| `core/app_runtime.go` | 引擎超时 60s → 40s，与 Dart 对齐 |
| `core/provider_hongguo_race.go`、`provider_hongguo.go`、`app_categories.go`、`provider_dsd_catalog.go` | 4 处子 goroutine 补 `recover` |
| `app/android/gradle.properties` | 加 `android.overridePathCheck=true`（中文路径下 AGP 要求） |

### 第二轮：乱序轮播（3 个 Dart 文件）

需求：每次打开 APP 的取剧序列都不该有规律。原实现虽有 `shuffle`，但只洗「网页分类第 1 页」那固定一批剧，且跨会话不记看过什么。

| 文件 | 修复 |
|---|---|
| `app/lib/store.dart` | 新增 `hg.feed.recent.v1` / `hg.feed.start.v1` 两组持久化 |
| `app/lib/webcat.dart` | 新增 `startFeedSession()` / `seedPages()`：随机起点页 + 多页并发混洗 + 越界回退 |
| `app/lib/feed_page.dart` | `Random.secure()` 种子、`_beginFeedSession()`、`_seedPool()`、`_remember()` 落盘、去重表全过滤时放宽一次、离开 >=20 分钟回前台重洗待播池 |

每部剧仍从第 1 集 / 上次进度起播，集数顺序未随机。

## 包含 / 排除

与 `PACKAGE-NOTES.md`（11-04 版）同一口径：包含 `app/lib/`、`app/android/`、`app/pubspec.*`、`app/test/`、`app/tool/`、`native/`、`probe/`、`docs/`、`third_party/duanjuapp-native/` 及根目录文档；排除 `app/build/`、`app/.dart_tool/`、`app/android/.gradle/`、`app/android/app/build/`、`app/.idea/`、`*.so`（`libhgnative.so` 需重新编译）、`*.apk`、`*.iml`、`*.class`、`*.log`、`app/android/local.properties`（含本机 SDK 路径）。

## 构建注意（本机实测）

1. **路径含中文**：AGP 会拒绝，已靠 `gradle.properties` 的 `android.overridePathCheck=true` 过；但 Dart AOT 快照工具仍会把路径读成乱码而找不到 `app.dill`，这个开关解决不了。**必须把 `app/` 复制到纯 ASCII 目录再执行 `flutter build apk`**，中文目录只用来改代码。
2. 编原生库：设 `GO_BIN` / `ANDROID_NDK_HOME` 后 `bash native/build_android.sh`，产物落到 `app/android/app/src/main/jniLibs/arm64-v8a/libhgnative.so`。
3. Go 依赖：`export GOPROXY=https://mirrors.aliyun.com/goproxy,direct`、`GOSUMDB=sum.golang.google.cn`；`native/go.mod` 的 replace 已是相对路径。
4. media-kit 的 `default-arm64-v8a.jar` 需已在本机 Gradle 缓存，或能访问其 GitHub releases。

## 验证记录（打包前）

- `go build ./...` = 0；`TestOfflineGorgon` / `TestOfflineHelios` = PASS；`go vet`（含 cgo）= 0
- `dart analyze lib` = No issues found
- arm64 `libhgnative.so` 15.8 MB，`HgRequest` / `HgFree` 符号已导出
- release APK 46.2 MB，包内 `libhgnative.so` / `libmpv.so` / `libflutter.so` / `libapp.so` / dex 齐全

详细分析与修复记录见资料库「duanjuapp最新1104版」文件夹内的四份文档（BUG 静态审计、实机复测修订、修复实施记录、乱序轮播修复记录）。
