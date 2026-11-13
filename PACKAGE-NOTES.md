# 打包说明（源码包）

打包时间：2026-11-04
对应版本：app 0.6.10+17（引擎已修通，真机验证通过）

## 包含

| 目录 / 文件 | 说明 |
|---|---|
| `HANDOFF-2026-11-04.md` | **先读这个**：现状、六个 bug、构建步骤、接口契约、风险应对 |
| `app/lib/` | Flutter 全部业务代码（17 个 dart 文件） |
| `app/android/` | Android 工程（Gradle 脚本、Manifest、图标资源、wrapper） |
| `app/pubspec.yaml` / `pubspec.lock` | 依赖声明与锁定版本 |
| `app/test/` | Dart 单测 |
| `app/tool/make_icon.py` | 五密度图标生成脚本（Pillow） |
| `native/` | Go FFI 桥接层源码 + `build_android.sh` |
| `probe/` | 引擎巡检工具（Windows 直接 `go run`） |
| `docs/` | 界面截图 + `CHANGELOG.md` 版本记录 |
| `third_party/duanjuapp-native/` | 「短聚」站源引擎源码（含本轮全部修复） |

## 已排除（构建产物 / 本机配置）

`app/build/`（约 1.4GB）、`app/android/.gradle/`、`app/android/app/build/`、
`app/.dart_tool/`、`app/.idea/`、`*.iml`、`*.class`、`*.log`、
`*.so`（含 `jniLibs/arm64-v8a/libhgnative.so`，需重新编译）、
`app/android/local.properties`（含本机 SDK 绝对路径）、
`releases/*.apk`（历史构建产物）

## 恢复后怎么构建

需要：Go 1.24+、Android NDK、Flutter 3.x、JDK 21。

1. **建 `app/android/local.properties`**（指向本机 SDK）：

   ```
   sdk.dir=C:\\<你的路径>\\android-sdk
   flutter.sdk=C:\\<你的路径>\\flutter
   ```

2. **编原生库**（先设两个变量，脚本里默认值是原作者机器路径）：

   ```bash
   export GO_BIN=/path/to/go/bin
   export ANDROID_NDK_HOME=/path/to/android-ndk
   bash native/build_android.sh
   ```

   产物输出到 `app/android/app/src/main/jniLibs/arm64-v8a/libhgnative.so`。

3. **编 APK**：

   ```bash
   cd app
   flutter pub get
   flutter build apk --release --target-platform android-arm64
   ```

4. **装机**（Git Bash 下必须加 `MSYS_NO_PATHCONV=1`）：

   ```bash
   MSYS_NO_PATHCONV=1 adb install -r build/app/outputs/flutter-apk/app-release.apk
   ```

## 依赖拉取

`proxy.golang.org` 在国内常 502，先设：

```bash
export GOPROXY=https://goproxy.cn,direct
export GOSUMDB=off
```

`native/go.mod` 的 `replace` 已是相对路径 `../third_party/duanjuapp-native`，无需修改。

详细架构、六个 bug 的定位过程、接口契约见 `HANDOFF-2026-11-04.md`。
